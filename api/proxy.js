export default async function handler(req, res) {
  // 处理预检请求
  if (req.method === 'OPTIONS') {
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'x-auth-token, content-type');
    res.status(200).end();
    return;
  }

  // 只允许 POST 请求
  if (req.method !== 'POST') {
    res.status(405).json({ error: 'Method Not Allowed' });
    return;
  }

  const targetUrl = 'https://95598.csg.cn/ucs/ma/wt/charge/queryChargesWithCode';

  try {
    const response = await fetch(targetUrl, {
      method: 'POST',
      headers: {
        'x-auth-token': req.headers['x-auth-token'] || '',
        'Content-Type': 'application/json',
        'Host': '95598.csg.cn'
      },
      body: JSON.stringify(req.body)
    });

    const data = await response.json();
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.status(response.status).json(data);
  } catch (error) {
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.status(502).json({ error: '代理请求失败', detail: error.message });
  }
}
