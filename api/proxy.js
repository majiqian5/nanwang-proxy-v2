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

  // 正确读取请求体（修复请求体丢失）
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  const body = Buffer.concat(chunks).toString();
  let parsed;
  try { parsed = JSON.parse(body); } catch {
    res.status(400).json({ error: '无效 JSON' });
    return;
  }

  const target = 'https://95598.csg.cn/ucs/ma/wt/charge/queryChargesWithCode';
  try {
    const controller = new AbortController();
    const id = setTimeout(() => controller.abort(), 25000);
    const resp = await fetch(target, {
      method: 'POST',
      headers: {
        'x-auth-token': req.headers['x-auth-token'] || '',
        'Content-Type': 'application/json',
        'Host': '95598.csg.cn'
      },
      body: JSON.stringify(parsed),
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
