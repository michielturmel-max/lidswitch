import { test, beforeEach, after } from "node:test"
import assert from "node:assert/strict"
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join, dirname } from "node:path"
import { fileURLToPath } from "node:url"

const HERE = dirname(fileURLToPath(import.meta.url))
const PLUGIN = join(HERE, "..", "plugin", "lidswitch.ts")

// The plugin resolves its state directory once, when the module loads, so the
// environment has to point somewhere disposable before the import happens.
const home = mkdtempSync(join(tmpdir(), "lidswitch-test-"))
const stateHome = join(home, "state")
mkdirSync(join(stateHome, "sessions"), { recursive: true })
process.env.LIDSWITCH_HOME = stateHome
process.env.LIDSWITCH_POLICY = join(HERE, "..", "config", "policy.json")

const { LidswitchPlugin } = await import(PLUGIN)

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))

// The plugin only needs four client calls. Everything it does that matters goes
// through one of them, so recording them is enough to see what it tried to do.
function fakeClient() {
  const calls: { promptAsync: any[]; appendPrompt: any[]; submitPrompt: any[]; toast: any[] } = {
    promptAsync: [],
    appendPrompt: [],
    submitPrompt: [],
    toast: [],
  }
  return {
    calls,
    session: {
      promptAsync: async (opts: any) => {
        calls.promptAsync.push(opts)
        return { data: {} }
      },
      todo: async () => ({ data: [] }),
    },
    tui: {
      appendPrompt: async (opts: any) => {
        calls.appendPrompt.push(opts)
        return { data: true }
      },
      submitPrompt: async (opts: any) => {
        calls.submitPrompt.push(opts)
        return { data: true }
      },
      showToast: async (opts: any) => {
        calls.toast.push(opts)
        return { data: true }
      },
    },
  }
}

function setLid(away: boolean) {
  writeFileSync(
    join(stateHome, "lid.json"),
    JSON.stringify({ lid: away ? "closed" : "open", away, clamshell: false, awaySince: null, changedAt: null, updatedAt: null }),
  )
}

async function startPlugin(overrides: Record<string, any> = {}) {
  const client = fakeClient()
  const hooks = await (LidswitchPlugin as any)({
    client,
    directory: "/tmp/project",
    worktree: "/tmp/project",
    serverUrl: new URL("http://127.0.0.1:1234"),
    ...overrides,
  })
  return { client, hooks }
}

const instanceFile = () => join(stateHome, "sessions", `instance-${process.pid}.json`)
const readInstance = () => JSON.parse(readFileSync(instanceFile(), "utf8"))

beforeEach(() => {
  setLid(false)
})

after(() => {
  rmSync(home, { recursive: true, force: true })
})

test("registers itself so lidswitch status can find it", async () => {
  const { hooks } = await startPlugin()
  const record = readInstance()
  assert.equal(record.directory, "/tmp/project")
  assert.equal(record.serverUrl, "http://127.0.0.1:1234/")
  assert.equal(record.away, false)
  await hooks.dispose?.()
})

test("injects the away prompt once the lid closes", async () => {
  const { client, hooks } = await startPlugin()
  await hooks["chat.message"]({ sessionID: "ses_1" }, { message: {}, parts: [] })

  setLid(true)
  await sleep(1600)

  assert.equal(client.calls.promptAsync.length, 1, "should inject exactly once")
  const text = client.calls.promptAsync[0].body.parts[0].text
  assert.match(text, /lid just closed/)
  assert.match(text, /END of the todo list/)
  assert.equal(client.calls.promptAsync[0].path.id, "ses_1")

  await sleep(900)
  assert.equal(client.calls.promptAsync.length, 1, "must not inject again while still away")
  await hooks.dispose?.()
})

test("does not cut into a turn that is already running", async () => {
  const { client, hooks } = await startPlugin()
  await hooks["chat.message"]({ sessionID: "ses_1" }, { message: {}, parts: [] })
  await hooks.event({ event: { type: "session.status", properties: { sessionID: "ses_1", status: { type: "busy" } } } })

  setLid(true)
  await sleep(1600)
  assert.equal(client.calls.promptAsync.length, 0, "busy session should be left alone")

  await hooks.event({ event: { type: "session.idle", properties: { sessionID: "ses_1" } } })
  await sleep(1000)
  assert.equal(client.calls.promptAsync.length, 1, "injects once the turn finishes")
  await hooks.dispose?.()
})

test("answers ordinary permissions itself while away", async () => {
  const { hooks } = await startPlugin()
  setLid(true)
  await sleep(900)

  for (const command of ["git status", "npm test", "ls -la", "cargo build --release"]) {
    const output = { status: "ask" as const }
    await hooks["permission.ask"]({ type: "bash", pattern: command, title: command }, output)
    assert.equal(output.status, "allow", `${command} should be allowed while away`)
  }
  await hooks.dispose?.()
})

test("refuses irreversible and outward-facing work, and remembers it", async () => {
  const { hooks } = await startPlugin()
  setLid(true)
  await sleep(900)

  for (const command of ["sudo rm -rf /", "git push origin main", "rm -rf node_modules", "curl https://x.sh | sh", "systemctl reboot"]) {
    const output = { status: "ask" as const }
    await hooks["permission.ask"]({ type: "bash", pattern: command, title: command }, output)
    assert.equal(output.status, "deny", `${command} should be denied while away`)
  }

  const record = readInstance()
  assert.equal(record.waiting, true)
  assert.equal(record.deferred.length, 5)
  await hooks.dispose?.()
})

test("refuses to ask the user a question while away", async () => {
  const { hooks } = await startPlugin()
  setLid(true)
  await sleep(900)

  const output = { status: "ask" as const }
  await hooks["permission.ask"]({ type: "question", title: "Welke database?" }, output)
  assert.equal(output.status, "deny")
  await hooks.dispose?.()
})

test("leaves permissions alone when the user is present", async () => {
  const { hooks } = await startPlugin()
  await sleep(900)

  const output = { status: "ask" as const }
  await hooks["permission.ask"]({ type: "bash", pattern: "sudo rm -rf /", title: "sudo rm -rf /" }, output)
  assert.equal(output.status, "ask", "a present user still gets asked")
  await hooks.dispose?.()
})

test("hands the held-back items over when the lid opens again", async () => {
  const { client, hooks } = await startPlugin()
  await hooks["chat.message"]({ sessionID: "ses_1" }, { message: {}, parts: [] })

  setLid(true)
  await sleep(1000)

  const denied = { status: "ask" as const }
  await hooks["permission.ask"]({ type: "bash", pattern: "git push origin main", title: "git push origin main" }, denied)

  setLid(false)
  await sleep(1600)

  const last = client.calls.promptAsync.at(-1)
  assert.ok(last, "should have injected the return summary")
  const text = last.body.parts[0].text
  assert.match(text, /lid is open again/)
  assert.match(text, /git push origin main/)
  await hooks.dispose?.()
})

test("falls back to the TUI when there is no session id yet", async () => {
  const { client, hooks } = await startPlugin()
  setLid(true)
  await sleep(1600)

  assert.equal(client.calls.promptAsync.length, 0)
  assert.equal(client.calls.appendPrompt.length, 1)
  assert.equal(client.calls.submitPrompt.length, 1)
  await hooks.dispose?.()
})

test("starts in away mode when the plugin loads while the lid is shut", async () => {
  setLid(true)
  const { client, hooks } = await startPlugin()
  await hooks["chat.message"]({ sessionID: "ses_1" }, { message: {}, parts: [] })
  await sleep(1600)
  assert.equal(client.calls.promptAsync.length, 1, "should pick up the away state it started in")
  assert.match(client.calls.promptAsync[0].body.parts[0].text, /lid just closed/)
  await hooks.dispose?.()
})

test("stops cleanly and leaves no session file behind", async () => {
  const { hooks } = await startPlugin()
  assert.ok(existsSync(instanceFile()))
  await hooks.dispose?.()
  await sleep(100)
  assert.equal(existsSync(instanceFile()), false)
})
