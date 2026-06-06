export default async function handler(req, res) {
  // 预检请求
  if (req.method === 'OPTIONS') {
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'x-auth-token, content-type');
    res.status(200).end();
    return;
  }

  if (req.method !== 'POST') {
    res.status(405).json({ error: 'Method Not Allowed' });
    return;
  }

  // 读取并解析请求体
  const chunks = [];
  for await (const chunk of req) {
    chunks.push(chunk);
  }
  const body = Buffer.concat(chunks).toString();
  let parsedBody;
  try {
    parsedBody = JSON.parse(body);
  } catch (e) {
    res.status(400).json({ error: '无效的 JSON 请求体' });
    return;
  }

  const targetUrl = 'https://95598.csg.cn/ucs/ma/wt/charge/queryChargesWithCode';

  try {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 25000);

    const response = await fetch(targetUrl, {
      method: 'POST',
      headers: {
        'x-auth-token': req.headers['x-auth-token'] || '',
        'Content-Type': 'application/json',
        'Host': '95598.csg.cn'
      },
      body: JSON.stringify(parsedBody),   // 关键：使用解析后的对象
      signal: controller.signal
    });

    clearTimeout(timeout);
    const data = await response.json();

    res.setHeader('Access-Control-Allow-Origin', '*');
    res.status(response.status).json(data);
  } catch (error) {
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.status(502).json({ error: '代理请求失败', detail: error.message });
  }
}
