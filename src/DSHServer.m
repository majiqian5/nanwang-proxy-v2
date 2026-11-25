#import "DSHServer.h"
#import "DSHConfig.h"
#import "DSHPaths.h"
#import "DSHHID.h"
#import "DSHInspector.h"
#import "DSHApps.h"
#import "DSHScreen.h"
#import "DSHSkin.h"
#import "DSHEngine.h"

#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <errno.h>

@interface DSHServer ()
@property (nonatomic, assign) int listenFD;
@property (nonatomic, assign) NSInteger port;
@property (nonatomic, copy) NSString *bindAddress;
@property (nonatomic, strong) dispatch_queue_t acceptQueue;
@property (nonatomic, strong) dispatch_queue_t inputQueue;
@property (nonatomic, assign) BOOL running;
@end

@implementation DSHServer

+ (instancetype)shared {
    static DSHServer *srv;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        srv = [DSHServer new];
        srv.inputQueue = dispatch_queue_create("com.zaka.dsh.input", DISPATCH_QUEUE_SERIAL);
    });
    return srv;
}

- (BOOL)isRunning { return self.running; }

#pragma mark - Lifecycle

- (BOOL)start {
    if (self.running) return YES;
    DSHConfig *cfg = [DSHConfig shared];
    self.port = cfg.port;

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        DSHLog(@"socket() failed: %d", errno);
        return NO;
    }
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)self.port);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        DSHLog(@"bind 127.0.0.1:%ld failed: %d", (long)self.port, errno);
        close(fd);
        return NO;
    }
    if (listen(fd, 32) != 0) {
        DSHLog(@"listen failed: %d", errno);
        close(fd);
        return NO;
    }
    self.listenFD = fd;
    self.bindAddress = @"127.0.0.1";
    self.running = YES;

    self.acceptQueue = dispatch_queue_create("com.zaka.dsh.accept", DISPATCH_QUEUE_SERIAL);
    dispatch_async(self.acceptQueue, ^{
        while (self.running) {
            struct sockaddr_in peer;
            socklen_t len = sizeof(peer);
            int client = accept(self.listenFD, (struct sockaddr *)&peer, &len);
            if (client < 0) {
                if (!self.running) break;
                usleep(20 * 1000);
                continue;
            }
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                @autoreleasepool {
                    [self serveClient:client];
                }
            });
        }
    });

    DSHLog(@"control plane listening on %@:%ld", self.bindAddress, (long)self.port);
    return YES;
}

- (void)stop {
    self.running = NO;
    if (self.listenFD > 0) {
        shutdown(self.listenFD, SHUT_RDWR);
        close(self.listenFD);
        self.listenFD = -1;
    }
}

#pragma mark - HTTP plumbing

- (NSData *)readRequestFrom:(int)client {
    struct timeval tv = { .tv_sec = 6, .tv_usec = 0 };
    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    NSMutableData *buffer = [NSMutableData data];
    char chunk[8192];
    NSInteger contentLength = -1;
    NSInteger headerEnd = -1;

    while (YES) {
        ssize_t n = recv(client, chunk, sizeof(chunk), 0);
        if (n <= 0) break;
        [buffer appendBytes:chunk length:(NSUInteger)n];

        if (headerEnd < 0) {
            NSRange r = [buffer rangeOfData:[@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]
                                     options:0 range:NSMakeRange(0, buffer.length)];
            if (r.location != NSNotFound) {
                headerEnd = (NSInteger)(r.location + r.length);
                NSString *head = [[NSString alloc] initWithData:[buffer subdataWithRange:NSMakeRange(0, headerEnd)]
                                                       encoding:NSUTF8StringEncoding];
                for (NSString *line in [head componentsSeparatedByString:@"\r\n"]) {
                    NSString *lower = line.lowercaseString;
                    if ([lower hasPrefix:@"content-length:"]) {
                        contentLength = [[line substringFromIndex:15] integerValue];
                    }
                }
            }
        }
        if (headerEnd > 0) {
            NSInteger bodyNeeded = MAX(0, contentLength);
            if ((NSInteger)buffer.length - headerEnd >= bodyNeeded) break;
        }
        if (buffer.length > 4 * 1024 * 1024) break; // hard cap
    }
    return buffer;
}

- (void)respond:(int)client status:(int)status contentType:(NSString *)type body:(NSData *)body {
    NSString *reason = status == 200 ? @"OK" : (status == 400 ? @"Bad Request" :
                       (status == 401 ? @"Unauthorized" : (status == 404 ? @"Not Found" : @"Error")));
    NSMutableString *head = [NSMutableString stringWithFormat:
        @"HTTP/1.1 %d %@\r\n"
        @"Content-Type: %@\r\n"
        @"Content-Length: %lu\r\n"
        @"Connection: close\r\n"
        @"Cache-Control: no-store\r\n\r\n",
        status, reason, type, (unsigned long)body.length];
    NSMutableData *payload = [[head dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    if (body) [payload appendData:body];
    send(client, payload.bytes, payload.length, 0);
}

- (void)respondJSON:(int)client status:(int)status object:(id)object {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object ?: @{} options:0 error:NULL];
    [self respond:client status:status contentType:@"application/json; charset=utf-8" body:data];
}

- (void)serveClient:(int)client {
    NSData *raw = [self readRequestFrom:client];
    if (raw.length == 0) { close(client); return; }

    NSString *text = [[NSString alloc] initWithData:raw encoding:NSUTF8StringEncoding];
    if (!text) { close(client); return; }
    NSRange headerRange = [text rangeOfString:@"\r\n\r\n"];
    NSString *head = headerRange.location == NSNotFound ? text : [text substringToIndex:headerRange.location];
    NSData *bodyData = nil;
    if (headerRange.location != NSNotFound) {
        NSUInteger start = headerRange.location + headerRange.length;
        if (start < raw.length) bodyData = [raw subdataWithRange:NSMakeRange(start, raw.length - start)];
    }

    NSArray<NSString *> *lines = [head componentsSeparatedByString:@"\r\n"];
    NSString *requestLine = lines.firstObject ?: @"";
    NSArray<NSString *> *parts = [requestLine componentsSeparatedByString:@" "];
    NSString *method = parts.count > 0 ? parts[0] : @"GET";
    NSString *path = parts.count > 1 ? parts[1] : @"/";

    NSString *queryString = @"";
    NSRange q = [path rangeOfString:@"?"];
    if (q.location != NSNotFound) {
        queryString = [path substringFromIndex:q.location + 1];
        path = [path substringToIndex:q.location];
    }
    NSMutableDictionary *query = [NSMutableDictionary dictionary];
    for (NSString *pair in [queryString componentsSeparatedByString:@"&"]) {
        NSRange eq = [pair rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;
        NSString *k = [pair substringToIndex:eq.location];
        NSString *v = [pair substringFromIndex:eq.location + 1];
        query[k] = [v stringByRemovingPercentEncoding] ?: v;
    }

    // Token check
    NSString *token = nil;
    for (NSString *line in lines) {
        if ([line.lowercaseString hasPrefix:@"x-dsh-token:"]) {
            token = [[line substringFromIndex:12] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        } else if ([line.lowercaseString hasPrefix:@"authorization:"]) {
            NSString *v = [[line substringFromIndex:14] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if ([v.lowercaseString hasPrefix:@"bearer "]) token = [v substringFromIndex:7];
        }
    }
    if (!token) token = query[@"token"];

    if (![path isEqualToString:@"/v1/ping"] && ![path isEqualToString:@"/health"]) {
        if (![token isEqualToString:[DSHConfig shared].token]) {
            [self respondJSON:client status:401 object:@{ @"ok": @NO, @"error": @"unauthorized" }];
            close(client);
            return;
        }
    }

    id body = nil;
    if (bodyData.length) {
        body = [NSJSONSerialization JSONObjectWithData:bodyData options:0 error:NULL];
    }

    BOOL asyncHandled = NO;
    @try {
        [self route:path method:method query:query body:body client:client asyncOut:&asyncHandled];
    } @catch (NSException *e) {
        DSHLog(@"handler exception %@: %@", path, e.reason);
        [self respondJSON:client status:400 object:@{ @"ok": @NO, @"error": e.reason ?: @"exception" }];
    }
    if (!asyncHandled) close(client);
}

#pragma mark - Routing

- (void)route:(NSString *)path method:(NSString *)method query:(NSDictionary *)query body:(id)body client:(int)client asyncOut:(BOOL *)asyncOut {
    DSHConfig *cfg = [DSHConfig shared];
    NSDictionary *payload = [body isKindOfClass:[NSDictionary class]] ? body : @{};

    if ([path isEqualToString:@"/v1/ping"] || [path isEqualToString:@"/health"]) {
        [self respondJSON:client status:200 object:@{ @"ok": @YES, @"service": @"dsh-engine" }];
        return;
    }

    if ([path isEqualToString:@"/v1/status"]) {
        [self respondJSON:client status:200 object:@{ @"ok": @YES, @"status": [[DSHEngine shared] status] }];
        return;
    }

    if ([path isEqualToString:@"/v1/screen"]) {
        [self respondJSON:client status:200 object:@{ @"ok": @YES, @"screen": [[DSHScreen shared] screenInfo] }];
        return;
    }

    if ([path isEqualToString:@"/v1/ui"]) {
        NSInteger depth = [query[@"depth"] integerValue] ?: 8;
        NSInteger nodes = [query[@"nodes"] integerValue] ?: 900;
        NSDictionary *snapshot = [[DSHInspector shared] snapshotWithMaxDepth:depth maxNodes:nodes];
        [self respondJSON:client status:200 object:@{ @"ok": @YES, @"snapshot": snapshot ?: @{} }];
        return;
    }

    if ([path isEqualToString:@"/v1/apps"]) {
        NSString *q = query[@"q"];
        NSArray *apps = q.length ? [[DSHApps shared] installedApplicationsMatching:q]
                                 : [[DSHApps shared] installedApplications];
        [self respondJSON:client status:200 object:@{ @"ok": @YES, @"count": @(apps.count), @"apps": apps }];
        return;
    }

    if ([path isEqualToString:@"/v1/skin"]) {
        if ([method isEqualToString:@"POST"]) {
            NSString *ident = payload[@"id"] ?: query[@"id"];
            BOOL ok = [[DSHSkinManager shared] selectSkinWithIdentifier:ident];
            [[DSHEngine shared] refreshSkin];
            [self respondJSON:client status:ok ? 200 : 404
                       object:@{ @"ok": @(ok), @"current": [[DSHSkinManager shared] current].identifier ?: @"" }];
            return;
        }
        [self respondJSON:client status:200 object:@{ @"ok": @YES,
                                                      @"current": [[DSHSkinManager shared] current].identifier ?: @"",
                                                      @"skins": [[DSHSkinManager shared] skinSummaries] }];
        return;
    }

    if ([path isEqualToString:@"/v1/screenshot"]) {
        if ([method isEqualToString:@"POST"]) {
            NSString *target = payload[@"path"] ?: query[@"path"];
            if (target.length == 0) target = DSHDataFile(@"screenshot.png");
            BOOL ok = [[DSHScreen shared] captureToPath:target];
            [self respondJSON:client status:ok ? 200 : 503
                       object:@{ @"ok": @(ok), @"path": target,
                                 @"source": [[DSHScreen shared] lastCaptureSource] ?: @"none" }];
            return;
        }
        NSData *png = [[DSHScreen shared] capturePNG];
        if (!png) {
            [self respondJSON:client status:503 object:@{ @"ok": @NO, @"error": @"no capture backend" }];
            return;
        }
        [self respond:client status:200 contentType:@"image/png" body:png];
        return;
    }

    if ([path isEqualToString:@"/v1/config"]) {
        if ([method isEqualToString:@"POST"]) {
            [self applyConfigPatch:payload];
            [self respondJSON:client status:200 object:@{ @"ok": @YES, @"status": [[DSHEngine shared] status] }];
            return;
        }
        [self respondJSON:client status:200 object:@{ @"ok": @YES, @"config": [self configDictionary] }];
        return;
    }

    // ---- input ----
    if ([path hasPrefix:@"/v1/tap"] || [path hasPrefix:@"/v1/doubletap"] || [path hasPrefix:@"/v1/longpress"] ||
        [path hasPrefix:@"/v1/swipe"] || [path hasPrefix:@"/v1/drag"] || [path hasPrefix:@"/v1/type"] ||
        [path hasPrefix:@"/v1/key"] || [path hasPrefix:@"/v1/home"] || [path hasPrefix:@"/v1/lock"] ||
        [path hasPrefix:@"/v1/app"] || [path hasPrefix:@"/v1/pet"] || [path hasPrefix:@"/v1/bubble"] ||
        [path hasPrefix:@"/v1/gesture"]) {

        *asyncOut = YES;
        dispatch_async(self.inputQueue, ^{
            @autoreleasepool {
                id<NSObject> result = [self performInputPath:path query:query payload:payload];
                if ([result isKindOfClass:[NSDictionary class]]) {
                    [self respondJSON:client status:200 object:result];
                } else {
                    [self respondJSON:client status:400 object:@{ @"ok": @NO, @"error": @"bad request" }];
                }
                close(client);
            }
        });
        return; // client is closed inside the input queue
    }

    [self respondJSON:client status:404 object:@{ @"ok": @NO, @"error": @"unknown endpoint", @"path": path }];
}

- (NSDictionary *)configDictionary {
    DSHConfig *c = [DSHConfig shared];
    return @{
        @"port": @(c.port),
        @"token": c.token ?: @"",
        @"skinIdentifier": c.skinIdentifier ?: @"",
        @"serverEnabled": @(c.serverEnabled),
        @"bubbleEnabled": @(c.bubbleEnabled),
        @"petEnabled": @(c.petEnabled),
        @"accessibilityFallback": @(c.accessibilityFallback),
        @"hidScaleToPixels": @(c.hidScaleToPixels),
        @"configPath": [c configPath] ?: @"",
    };
}

- (void)applyConfigPatch:(NSDictionary *)patch {
    DSHConfig *c = [DSHConfig shared];
    if (patch[@"bubbleEnabled"]) [c setBubbleEnabled:[patch[@"bubbleEnabled"] boolValue]];
    if (patch[@"petEnabled"]) [c setPetEnabled:[patch[@"petEnabled"] boolValue]];
    if (patch[@"accessibilityFallback"]) [c setAccessibilityFallback:[patch[@"accessibilityFallback"] boolValue]];
    if (patch[@"hidScaleToPixels"]) {
        c.hidScaleToPixels = [patch[@"hidScaleToPixels"] boolValue];
        [DSHHID shared].hidScaleToPixels = c.hidScaleToPixels;
    }
    if (patch[@"skinIdentifier"]) c.skinIdentifier = patch[@"skinIdentifier"];
    BOOL portChanged = NO;
    if (patch[@"port"]) {
        NSInteger newPort = [patch[@"port"] integerValue];
        if (newPort > 0 && newPort < 65536 && newPort != c.port) { c.port = newPort; portChanged = YES; }
    }
    [c save];
    if (portChanged) {
        [self stop];
        [self start];
    }
    [[DSHEngine shared] applyConfig];
}

#pragma mark - Input actions

- (NSNumber *)number:(NSDictionary *)dict key:(NSString *)key fallback:(double)fallback {
    id v = dict[key];
    if ([v isKindOfClass:[NSNumber class]]) return v;
    if ([v isKindOfClass:[NSString class]]) {
        NSScanner *scanner = [NSScanner scannerWithString:v];
        double parsed = 0;
        if ([scanner scanDouble:&parsed] && scanner.isAtEnd) return @(parsed);
    }
    return @(fallback);
}

- (NSDictionary *)performInputPath:(NSString *)path query:(NSDictionary *)query payload:(NSDictionary *)payload {
    DSHHID *hid = [DSHHID shared];
    NSMutableDictionary *args = [payload mutableCopy] ?: [NSMutableDictionary dictionary];
    for (NSString *k in query) if (!args[k]) args[k] = query[k];

    if ([path isEqualToString:@"/v1/tap"]) {
        CGPoint p = CGPointMake([self number:args key:@"x" fallback:0].doubleValue,
                                [self number:args key:@"y" fallback:0].doubleValue);
        BOOL ok = [hid tapAt:p];
        return @{ @"ok": @(ok), @"action": @"tap", @"point": @[ @(p.x), @(p.y) ], @"backend": hid.backendName };
    }

    if ([path isEqualToString:@"/v1/doubletap"]) {
        CGPoint p = CGPointMake([self number:args key:@"x" fallback:0].doubleValue,
                                [self number:args key:@"y" fallback:0].doubleValue);
        BOOL ok = [hid doubleTapAt:p];
        return @{ @"ok": @(ok), @"action": @"doubletap", @"point": @[ @(p.x), @(p.y) ] };
    }

    if ([path isEqualToString:@"/v1/longpress"]) {
        CGPoint p = CGPointMake([self number:args key:@"x" fallback:0].doubleValue,
                                [self number:args key:@"y" fallback:0].doubleValue);
        NSTimeInterval dur = [self number:args key:@"duration" fallback:1.0].doubleValue;
        BOOL ok = [hid longPressAt:p duration:dur];
        return @{ @"ok": @(ok), @"action": @"longpress", @"duration": @(dur) };
    }

    if ([path isEqualToString:@"/v1/swipe"] || [path isEqualToString:@"/v1/drag"]) {
        CGPoint a = CGPointMake([self number:args key:@"x1" fallback:0].doubleValue,
                                [self number:args key:@"y1" fallback:0].doubleValue);
        CGPoint b = CGPointMake([self number:args key:@"x2" fallback:0].doubleValue,
                                [self number:args key:@"y2" fallback:0].doubleValue);
        NSTimeInterval dur = [self number:args key:@"duration" fallback:0.35].doubleValue;
        BOOL ok = [path isEqualToString:@"/v1/drag"] ? [hid dragFrom:a to:b duration:dur]
                                                     : [hid swipeFrom:a to:b duration:dur];
        return @{ @"ok": @(ok), @"action": path.lastPathComponent };
    }

    if ([path isEqualToString:@"/v1/type"]) {
        NSString *text = args[@"text"];
        if (![text isKindOfClass:[NSString class]]) return nil;
        BOOL ok = [hid typeText:text];
        return @{ @"ok": @(ok), @"action": @"type", @"length": @(text.length) };
    }

    if ([path isEqualToString:@"/v1/key"]) {
        NSInteger usage = [self number:args key:@"usage" fallback:0].integerValue;
        NSArray *mods = [args[@"modifiers"] isKindOfClass:[NSArray class]] ? args[@"modifiers"] : @[];
        BOOL ok = [hid sendKeyUsage:(uint16_t)usage modifiers:mods];
        return @{ @"ok": @(ok), @"action": @"key", @"usage": @(usage) };
    }

    if ([path isEqualToString:@"/v1/home"]) {
        return @{ @"ok": @([hid pressHome]), @"action": @"home" };
    }

    if ([path isEqualToString:@"/v1/lock"]) {
        return @{ @"ok": @([hid lockDevice]), @"action": @"lock" };
    }

    if ([path isEqualToString:@"/v1/app/open"]) {
        NSString *bid = args[@"bundleId"] ?: args[@"bid"];
        BOOL ok = [[DSHApps shared] openApplicationWithBundleIdentifier:bid];
        return @{ @"ok": @(ok), @"action": @"app.open", @"bundleId": bid ?: @"" };
    }

    if ([path isEqualToString:@"/v1/pet"]) {
        NSString *action = args[@"action"] ?: @"toggle";
        DSHEngine *engine = [DSHEngine shared];
        BOOL target = [action isEqualToString:@"show"] ? YES
                     : [action isEqualToString:@"hide"] ? NO
                     : ![DSHConfig shared].petEnabled;
        [engine setPetEnabled:target];
        if (args[@"state"]) [engine setPetState:args[@"state"]];
        return @{ @"ok": @YES, @"petEnabled": @(target), @"state": args[@"state"] ?: @"" };
    }

    if ([path isEqualToString:@"/v1/bubble"]) {
        NSString *action = args[@"action"] ?: @"toggle";
        BOOL target = [action isEqualToString:@"show"] ? YES
                     : [action isEqualToString:@"hide"] ? NO
                     : ![DSHConfig shared].bubbleEnabled;
        [[DSHEngine shared] setBubbleEnabled:target];
        return @{ @"ok": @YES, @"bubbleEnabled": @(target) };
    }

    if ([path isEqualToString:@"/v1/gesture"]) {
        NSArray *steps = args[@"steps"];
        if (![steps isKindOfClass:[NSArray class]]) return nil;
        NSMutableArray *results = [NSMutableArray array];
        for (NSDictionary *step in steps) {
            if (![step isKindOfClass:[NSDictionary class]]) continue;
            NSString *type = step[@"type"] ?: @"tap";
            NSDictionary *res = nil;
            if ([type isEqualToString:@"tap"]) res = [self performInputPath:@"/v1/tap" query:@{} payload:step];
            else if ([type isEqualToString:@"longpress"]) res = [self performInputPath:@"/v1/longpress" query:@{} payload:step];
            else if ([type isEqualToString:@"swipe"]) res = [self performInputPath:@"/v1/swipe" query:@{} payload:step];
            else if ([type isEqualToString:@"type"]) res = [self performInputPath:@"/v1/type" query:@{} payload:step];
            else if ([type isEqualToString:@"wait"]) {
                double seconds = [self number:step key:@"duration" fallback:0.5].doubleValue;
                usleep((useconds_t)(MAX(0.0, MIN(seconds, 10.0)) * 1000000));
                res = @{ @"ok": @YES, @"action": @"wait" };
            }
            [results addObject:res ?: @{ @"ok": @NO, @"type": type }];
            usleep(40 * 1000);
        }
        return @{ @"ok": @YES, @"action": @"gesture", @"results": results };
    }

    return nil;
}

@end
