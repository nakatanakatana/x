import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";

import worker, { Counter } from "./index.js";

function createCounter() {
  const values = new Map();
  let putCalls = 0;
  const storage = {
    async get(key) {
      return values.get(key);
    },
    async put(key, value) {
      putCalls += 1;
      values.set(key, value);
    },
  };

  return {
    counter: new Counter({ storage }),
    get putCalls() {
      return putCalls;
    },
  };
}

function createEnvironment(counter) {
  return {
    COUNTER: {
      idFromName(name) {
        assert.equal(name, "demo");
        return { name };
      },
      get(id) {
        assert.equal(id.name, "demo");
        return { fetch: (request) => counter.fetch(request) };
      },
    },
  };
}

async function assertJson(response, expectedBody) {
  assert.equal(
    response.headers.get("content-type"),
    "application/json; charset=utf-8",
  );
  assert.deepEqual(await response.json(), expectedBody);
}

test("GET / returns zero for a new counter", async () => {
  const { counter } = createCounter();
  const response = await worker.fetch(
    new Request("https://example.test/"),
    createEnvironment(counter),
  );

  assert.equal(response.status, 200);
  await assertJson(response, { count: 0 });
});

test("POST / increments and persists the counter for a later GET", async () => {
  const counterFixture = createCounter();
  const { counter } = counterFixture;
  const environment = createEnvironment(counter);

  const postResponse = await worker.fetch(
    new Request("https://example.test/", { method: "POST" }),
    environment,
  );
  assert.equal(postResponse.status, 200);
  await assertJson(postResponse, { count: 1 });

  const getResponse = await worker.fetch(
    new Request("https://example.test/"),
    environment,
  );
  assert.equal(getResponse.status, 200);
  await assertJson(getResponse, { count: 1 });
  assert.equal(counterFixture.putCalls, 1);
});

test("an unsupported path returns 404 without calling the Durable Object", async () => {
  const response = await worker.fetch(
    new Request("https://example.test/other"),
    {
      COUNTER: {
        idFromName() {
          throw new Error("the Durable Object should not be requested");
        },
      },
    },
  );

  assert.equal(response.status, 404);
  await assertJson(response, { error: "not_found" });
});

test("an unsupported method returns 405 and advertises the allowed methods", async () => {
  const response = await worker.fetch(
    new Request("https://example.test/", { method: "PUT" }),
    {
      COUNTER: {
        idFromName() {
          throw new Error("the Durable Object should not be requested");
        },
      },
    },
  );

  assert.equal(response.status, 405);
  assert.equal(response.headers.get("allow"), "GET, POST");
  await assertJson(response, { error: "method_not_allowed" });
});

test("wrangler configuration registers the SQLite Durable Object migration", async () => {
  const config = JSON.parse(
    await readFile(new URL("./wrangler.jsonc", import.meta.url), "utf8"),
  );

  assert.equal(config.name, "celld-counter");
  assert.equal(config.main, "index.js");
  assert.deepEqual(config.durable_objects.bindings, [
    { name: "COUNTER", class_name: "Counter" },
  ]);
  assert.deepEqual(config.migrations, [
    { tag: "v1", new_sqlite_classes: ["Counter"] },
  ]);
});
