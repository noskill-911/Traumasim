const origin = 'https://noskill-911.github.io';
const headers = {
  'Access-Control-Allow-Origin': origin,
  'Access-Control-Allow-Headers': 'apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Cache-Control': 'no-store',
};

function respond(status: number, data: object) {
  return Response.json(data, { status, headers });
}

async function call(path: string, method: string, payload: object) {
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!key) throw new Error('missing server credential');
  const response = await fetch(Deno.env.get('SUPABASE_URL') + path, {
    method,
    headers: { apikey: key, Authorization: 'Bearer ' + key, 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
    signal: AbortSignal.timeout(12000),
  });
  return { response, data: await response.json().catch(() => null) };
}

async function invitation(action: string, hash: string, activation: string, user?: string) {
  const { response, data } = await call('/rest/v1/rpc/traumasim_activate_trainer_access', 'POST',
    { p_action: action, p_hash: hash, p_activation: activation, p_user: user });
  if (!response.ok) throw new Error('invitation operation failed');
  return data;
}

Deno.serve(async (request: Request) => {
  if (request.headers.get('Origin') !== origin) return respond(403, { message: 'Zugriff verweigert.' });
  if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers });
  if (request.method !== 'POST') return respond(405, { message: 'Methode nicht erlaubt.' });

  const input = await request.json().catch(() => null);
  if (typeof input?.code !== 'string' || !/^[a-f0-9]{64}$/.test(input.code)) {
    return respond(400, { message: 'Der Einladungslink ist ungültig.' });
  }
  const encoder = new TextEncoder();
  if (typeof input.password !== 'string' || input.password.length < 12 || encoder.encode(input.password).length > 72) {
    return respond(400, { message: 'Wähle ein Passwort mit mindestens 12 Zeichen und höchstens 72 UTF-8-Bytes.' });
  }

  const hash = Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', encoder.encode(input.code))),
    (byte) => byte.toString(16).padStart(2, '0')).join('');
  const activation = crypto.randomUUID();
  try {
    const claim = await invitation('claim', hash, activation);
    if (!claim) return respond(409, { message: 'Die Einladung ist abgelaufen, bereits verwendet oder gerade in Bearbeitung.' });
    try {
      const { response, data } = await call('/auth/v1/admin/users' + (claim.user_id ? '/' + claim.user_id : ''),
        claim.user_id ? 'PUT' : 'POST', { email: claim.email, password: input.password, email_confirm: true });
      if (!response.ok) {
        return respond(response.status >= 500 ? 503 : 400, {
          message: data?.code === 'weak_password'
            ? 'Dieses Passwort erfüllt die Anforderungen nicht. Wähle ein anderes.'
            : 'Das Konto konnte gerade nicht eingerichtet werden. Versuche es erneut.',
        });
      }
      const completed = await invitation('finish', hash, activation, data?.user?.id ?? data?.id);
      if (!completed) throw new Error('invitation completion failed');
      return respond(200, { email: completed.email });
    } finally {
      await invitation('release', hash, activation).catch(() => {});
    }
  } catch {
    return respond(503, { message: 'Die Einrichtung ist gerade nicht erreichbar. Versuche es erneut.' });
  }
});
