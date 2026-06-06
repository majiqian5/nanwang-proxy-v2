export default async function handler(req, res) {
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

  // 直接读取原始请求体文本，不解析也不修改
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  const rawBody = Buffer.concat(chunks).toString();

  try {
    const controller = new AbortController();
    const id = setTimeout(() => controller.abort(), 25000);
    const resp = await fetch('https://95598.csg.cn/ucs/ma/wt/charge/queryChargesWithCode', {
      method: 'POST',
      headers: {
        'x-auth-token': req.headers['x-auth-token'] || '',
        'Content-Type': 'application/json',
        'Host': '95598.csg.cn'
      },
      body: rawBody,          // 重要：直接使用原始字符串
      signal: controller.signal
    });
    clearTimeout(id);
    const data = await resp.json();
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.status(resp.status).json(data);
  } catch (e) {
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.status(502).json({ error: '代理请求失败', detail: e.message });
  }
}
