import http from 'node:http';

const target = 'http://127.0.0.1:6666';
const preferredPort = 16666;
let gateway;
let opening;

export function requestJupyter(route, token, options = {}) {
  return new Promise((resolve, reject) => {
    const headers = { ...(token ? { Authorization: 'token ' + token } : {}),
      ...(options.body ? { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(options.body) } : {}) };
    const request = http.request(target + route, { method: options.method ?? 'GET', headers, signal: AbortSignal.timeout(5000) },
      (response) => {
        const chunks = [];
        response.on('error', reject);
        response.on('data', (chunk) => chunks.push(chunk));
        response.on('end', () => resolve({
          ok: response.statusCode >= 200 && response.statusCode < 300,
          status: response.statusCode,
          json: async () => JSON.parse(Buffer.concat(chunks).toString('utf8'))
        }));
      });
    request.on('error', reject);
    request.end(options.body);
  });
}

async function createGateway() {
  const sockets = new Set();
  let origin;
  const validHost = (request) => request.headers.host === new URL(origin).host
    && request.url.startsWith('/') && !request.url.startsWith('//');
  const options = (request) => {
    const headers = { ...request.headers, host: '127.0.0.1:6666' };
    if (headers.origin === origin) headers.origin = target;
    if (headers.referer?.startsWith(origin + '/')) headers.referer = target + headers.referer.slice(origin.length);
    return { method: request.method, path: request.url, hostname: '127.0.0.1', port: 6666, headers };
  };
  const server = http.createServer((request, response) => {
    if (!validHost(request) || request.headers['sec-fetch-site'] === 'cross-site') {
      response.writeHead(403).end();
      return;
    }
    const upstream = http.request(options(request), (reply) => {
      const headers = { ...reply.headers };
      if (headers.location?.startsWith(target + '/')) headers.location = origin + headers.location.slice(target.length);
      response.writeHead(reply.statusCode, headers);
      reply.pipe(response);
    });
    upstream.on('error', () => {
      if (!response.headersSent) response.writeHead(502);
      response.end();
    });
    response.on('close', () => upstream.destroy());
    request.pipe(upstream);
  });
  server.on('connection', (socket) => {
    sockets.add(socket);
    socket.once('close', () => sockets.delete(socket));
  });
  server.on('upgrade', (request, client, first) => {
    if (!validHost(request) || request.headers.origin !== origin) { client.destroy(); return; }
    const upstream = http.request(options(request));
    upstream.on('upgrade', (reply, remote, buffer) => {
      client.write(`HTTP/1.1 ${reply.statusCode} ${reply.statusMessage}\r\n`);
      for (let i = 0; i < reply.rawHeaders.length; i += 2) {
        client.write(`${reply.rawHeaders[i]}: ${reply.rawHeaders[i + 1]}\r\n`);
      }
      client.write('\r\n');
      if (buffer.length) client.write(buffer);
      if (first.length) remote.write(first);
      remote.on('error', () => client.destroy());
      client.on('error', () => remote.destroy());
      client.on('close', () => remote.destroy());
      remote.on('close', () => client.destroy());
      client.pipe(remote).pipe(client);
    });
    upstream.on('response', () => client.destroy());
    upstream.on('error', () => client.destroy());
    upstream.end();
  });
  const listen = (port) => new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, '127.0.0.1', () => {
      server.off('error', reject);
      origin = 'http://127.0.0.1:' + server.address().port;
      resolve();
    });
  });
  try { await listen(preferredPort); }
  catch (error) { if (error.code !== 'EADDRINUSE') throw error; await listen(0); }
  return { origin, server, sockets };
}

export async function jupyterGateway() {
  if (gateway) return gateway.origin;
  opening ??= createGateway().then((result) => { gateway = result; return result; }).finally(() => { opening = undefined; });
  return (await opening).origin;
}

export async function closeJupyterGateway() {
  if (opening) await opening.catch(() => {});
  if (!gateway) return;
  const { server, sockets } = gateway;
  gateway = undefined;
  for (const socket of sockets) socket.destroy();
  await new Promise((resolve) => server.close(resolve));
}
