const JSON_CONTENT_TYPE = "application/json; charset=utf-8";

function json(body, init = {}) {
  const headers = new Headers(init.headers);
  headers.set("content-type", JSON_CONTENT_TYPE);
  return new Response(JSON.stringify(body), { ...init, headers });
}

export class Counter {
  constructor(state) {
    this.state = state;
  }

  async fetch(request) {
    if (request.method !== "GET" && request.method !== "POST") {
      return json(
        { error: "method_not_allowed" },
        { status: 405, headers: { Allow: "GET, POST" } },
      );
    }

    const current = (await this.state.storage.get("count")) ?? 0;
    if (request.method === "GET") {
      return json({ count: current });
    }

    const count = current + 1;
    await this.state.storage.put("count", count);
    return json({ count });
  }
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname !== "/") {
      return json({ error: "not_found" }, { status: 404 });
    }

    if (request.method !== "GET" && request.method !== "POST") {
      return json(
        { error: "method_not_allowed" },
        { status: 405, headers: { Allow: "GET, POST" } },
      );
    }

    const id = env.COUNTER.idFromName("demo");
    return env.COUNTER.get(id).fetch(request);
  },
};
