export const config = { runtime: 'edge' };

export default async function handler(req) {
  // 处理 CORS 预检请求
  if (req.method === 'OPTIONS') {
    return new Response(null, {
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'POST, OPTIONS',
        'Access-Control-Allow-Headers': 'x-auth-token, content-type',
      },
    });
  }

  // 只允许 POST 请求
  if (req.method !== 'POST') {
    return new Response(JSON.stringify({ error: 'Method Not Allowed' }), {
      status: 405,
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Content-Type': 'application/json',
      },
    });
  }

  const targetUrl = 'https://95598.csg.cn/ucs/ma/wt/charge/queryChargesWithCode';

  try {
    // 关键：直接透传原始请求体（不解析、不修改）
    const response = await fetch(targetUrl, {
      method: 'POST',
      headers: {
        'x-auth-token': req.headers.get('x-auth-token') || '',
        'Content-Type': 'application/json',
        'Host': '95598.csg.cn',
      },
      body: req.body, // 原始请求体直接转发
    });

    const data = await response.json();

    return new Response(JSON.stringify(data), {
      status: response.status,
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Content-Type': 'application/json',
      },
    });
  } catch (error) {
    return new Response(JSON.stringify({ error: '代理请求失败', detail: error.message }), {
      status: 502,
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Content-Type': 'application/json',
      },
    });
  }
}
