import type { Plugin } from "@opencode-ai/plugin"
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"

const STATE_HOME = process.env.LIDSWITCH_HOME ?? join(homedir(), ".local/state/lidswitch")
const SESSION_DIR = join(STATE_HOME, "sessions")
const LID_FILE = join(STATE_HOME, "lid.json")
const POLICY_FILE = process.env.LIDSWITCH_POLICY ?? join(homedir(), ".config/lidswitch/policy.json")
const TICK_MS = 750

// Away mode may act on its own for anything local and reversible. What is left
// out is what leaves this machine or cannot be taken back: those are recorded
// and handed to the user on return instead of being guessed at.
const DEFAULT_POLICY = {
  deny: {
    reason: "vereist de gebruiker",
    tools: ["question"],
    bash: [
      // privileges
      "sudo *",
      "su *",
      "doas *",
      "passwd *",
      "chown *",
      "chmod 777 *",
      "visudo*",
      "crontab*",
      // destruction
      "rm -rf *",
      "rm -fr *",
      "rm -r /*",
      "rm --recursive *",
      "rm --no-preserve-root *",
      "mkfs*",
      "dd if=*",
      "fdisk*",
      "parted*",
      "wipefs*",
      "shred *",
      // remote code
      "curl *| sh",
      "curl *| sh*",
      "curl *|bash*",
      "wget *| sh*",
      "wget *|bash*",
      // system changes
      "pacman -S*",
      "pacman -R*",
      "pacman -U*",
      "yay -S*",
      "paru -S*",
      "apt install*",
      "apt remove*",
      "systemctl *",
      "loginctl *",
      "shutdown*",
      "reboot*",
      "poweroff*",
      "halt*",
      // outward-facing
      "git push*",
      "git push --force*",
      "gh pr create*",
      "gh pr merge*",
      "gh release*",
      "gh repo delete*",
      "npm publish*",
      "pnpm publish*",
      "yarn publish*",
      "cargo publish*",
      "twine upload*",
      "docker push*",
      "ssh *",
      "scp *",
      "rsync *",
    ],
  },
  autonomy: {
    // Seconds the model may sit idle with open todos before it gets told to
    // carry on. 0 switches nudging off entirely.
    nudgeAfterSeconds: 300,
    maxNudges: 3,
  },
}

type LidState = { lid: string; away: boolean; awaySince: string | null }
type Blocked = {
  at: string
  type: string
  title: string
  pattern?: string
  reason: string
  handled?: boolean
}
type Done = { at: string; title: string }

type Policy = {
  deny: { reason: string; tools: string[]; bash: string[] }
  autonomy: { nudgeAfterSeconds: number; maxNudges: number }
}

function readJSON<T>(path: string, fallback: T): T {
  try {
    if (!existsSync(path)) return fallback
    return JSON.parse(readFileSync(path, "utf8")) as T
  } catch {
    return fallback
  }
}

function loadPolicy(): Policy {
  const user = readJSON<Record<string, unknown>>(POLICY_FILE, {})
  const deny = (user.deny ?? {}) as Record<string, unknown>
  const autonomy = (user.autonomy ?? {}) as Record<string, unknown>
  return {
    deny: {
      reason: (deny.reason as string) ?? DEFAULT_POLICY.deny.reason,
      tools: (deny.tools as string[]) ?? DEFAULT_POLICY.deny.tools,
      bash: (deny.bash as string[]) ?? DEFAULT_POLICY.deny.bash,
    },
    autonomy: { ...DEFAULT_POLICY.autonomy, ...(autonomy as Policy["autonomy"]) },
  }
}

// Glob match where only '*' is special. Every other character is literal, which
// matters because these patterns meet real shell strings full of brackets and
// question marks that must not be read as regex metacharacters.
function globToRegExp(pattern: string) {
  const escaped = pattern
    .split("*")
    .map((part) => part.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"))
    .join(".*")
  return new RegExp(`^${escaped}$`)
}

function bashDenied(command: string, policy: Policy): string | null {
  for (const pattern of policy.deny.bash) {
    if (globToRegExp(pattern).test(command)) return pattern
  }
  // A download piped into a shell is the same hazard however it is spaced, and
  // glob matching alone would wave "curl x |  sh" straight through.
  const flat = command.replace(/\s+/g, " ")
  if (/\b(curl|wget)\b/.test(flat) && /\|\s*(sudo\s+)?(ba|z|k)?sh\b/.test(flat)) return "curl|sh"
  return null
}

const AWAY_PROMPT = [
  "[lidswitch] The laptop lid just closed. The user is not present.",
  "",
  "Work autonomously from here:",
  "- Keep going on the open task until it is finished or genuinely blocked. Do not stop to report progress.",
  "- Anything you cannot do yourself, or that needs a human decision, goes to the END of the todo list as the last item. It must never sit in the middle blocking everything after it.",
  "- Do not wait for confirmation on ordinary work: reading, editing, tests, builds, linters, and git operations that stay local.",
  "- Anything irreversible or that reaches outside this machine (pushing, publishing, deploying, deleting, system packages, sudo) is off-limits. Record it as the final todo item instead.",
  "- Spread independent work across subagents to go faster. They run unattended too.",
  "",
  "Do not answer with a status update. Start or resume the work.",
].join("\n")

const RETURN_PROMPT = (blocked: Blocked[], doneCount: number, wasBusy: boolean) => {
  const lines = [
    "[lidswitch] The lid is open again and the user is back.",
    wasBusy
      ? "The previous run had not finished when the lid opened; continue where it stopped."
      : `Work finished while the lid was closed${doneCount ? ` (${doneCount} tool calls)` : ""}.`,
    "",
  ]
  if (blocked.length) {
    lines.push("These were held back because they need the user. Put them at the end of the todo list and ask about them now, in one go:")
    for (const item of blocked) {
      lines.push(`- ${item.title}${item.pattern ? `  [matched: ${item.pattern}]` : ""} - ${item.reason}`)
    }
  } else {
    lines.push("Nothing needed the user while they were away.")
  }
  lines.push("", "Report briefly what changed while the lid was closed, then continue.")
  return lines.join("\n")
}

const NUDGE_PROMPT = [
  "[lidswitch] The user is still away and the todo list is not empty.",
  "Continue with the next open item on your own. Do not ask questions; anything needing the user goes to the last todo item.",
].join("\n")

export const LidswitchPlugin: Plugin = async ({ client, directory, worktree, serverUrl }) => {
  const policy = loadPolicy()
  const instance = join(SESSION_DIR, `instance-${process.pid}.json`)

  let sessionID: string | undefined
  let busy = false
  let away = false
  let awaySince: number | null = null
  let injectedForAbsence = false
  let idleSince = Date.now()
  let nudges = 0
  let openTodos = 0
  const blocked: Blocked[] = []
  const done: Done[] = []

  let publishedAt = 0
  let dirty = false

  // The event bus fires on every streamed message part, so writing the status
  // file per event would be thousands of writes a turn. Coalesce instead.
  const publish = (force = false) => {
    dirty = true
    const now = Date.now()
    if (!force && now - publishedAt < 1000) return
    dirty = false
    publishedAt = now
    try {
      mkdirSync(SESSION_DIR, { recursive: true })
      writeFileSync(
        instance,
        JSON.stringify({
          pid: process.pid,
          serverUrl: String(serverUrl),
          directory,
          worktree,
          sessionID: sessionID ?? null,
          busy,
          waiting: blocked.some((b) => !b.handled),
          away,
          awaySince: awaySince ? new Date(awaySince).toISOString() : null,
          openTodos,
          deferred: blocked.filter((b) => !b.handled),
          recent: done.slice(-25),
          updatedAt: new Date().toISOString(),
        }),
      )
    } catch {
      // A status file that cannot be written must never take the session down.
    }
  }

  const inject = async (text: string) => {
    if (sessionID) {
      const res = await client.session.promptAsync({
        path: { id: sessionID },
        body: { parts: [{ type: "text", text }] },
      })
      if (!res.error) return true
    }
    // No session id yet, or that route refused. Fall back to the TUI attached
    // to this server, if there is one.
    const appended = await client.tui.appendPrompt({ body: { text }, query: { directory } })
    if (appended.error) return false
    const submitted = await client.tui.submitPrompt({ query: { directory } })
    return !submitted.error
  }

  const toast = (message: string, variant: "info" | "success" | "warning" | "error") => {
    client.tui.showToast({ body: { message, variant }, query: { directory } }).catch(() => {})
  }

  const handleArrival = async () => {
    const wasBusy = busy
    const held = blocked.filter((b) => !b.handled)
    await inject(RETURN_PROMPT(held, done.length, wasBusy))
    toast("Deksel open - je bent terug", "info")
    for (const item of held) item.handled = true
    awaySince = null
  }

  const tick = async () => {
    const state = readJSON<LidState>(LID_FILE, { lid: "open", away: false, awaySince: null })

    if (state.away !== away) {
      away = state.away
      if (away) {
        awaySince = Date.now()
        idleSince = Date.now()
        nudges = 0
        injectedForAbsence = false
        publish(true)
        return
      }
      await handleArrival()
      publish(true)
      return
    }

    if (!away) return

    // A turn that was already running finishes on its own, so the away prompt
    // is injected at the first idle moment rather than cutting into it.
    if (!injectedForAbsence && !busy) {
      if (await inject(AWAY_PROMPT)) {
        injectedForAbsence = true
        toast("Deksel dicht - werk gaat zelfstandig door", "info")
      }
      return
    }

    const { nudgeAfterSeconds, maxNudges } = policy.autonomy
    if (!injectedForAbsence || !nudgeAfterSeconds) return
    if (busy || nudges >= maxNudges) return
    if (Date.now() - idleSince < nudgeAfterSeconds * 1000) return
    if (openTodos === 0) return
    nudges++
    await inject(NUDGE_PROMPT)
  }

  const timer = setInterval(() => {
    tick().catch(() => {})
  }, TICK_MS)
  timer.unref?.()

  const flush = setInterval(() => {
    if (dirty) publish()
  }, 1500)
  flush.unref?.()

  const start = readJSON<LidState>(LID_FILE, { lid: "open", away: false, awaySince: null })
  away = start.away
  awaySince = start.awaySince ? Date.parse(start.awaySince) : null
  if (away) {
    awaySince = Date.now()
    injectedForAbsence = false
  }
  publish(true)

  return {
    dispose: async () => {
      clearInterval(timer)
      clearInterval(flush)
      rmSync(instance, { force: true })
    },

    "chat.message": async (input) => {
      sessionID = input.sessionID
      publish()
    },

    event: async ({ event }) => {
      const props = (event as { properties?: Record<string, unknown> }).properties ?? {}
      const id = props.sessionID as string | undefined
      if (id && id !== sessionID) {
        sessionID = id
        publish(true)
      }

      switch (event.type) {
        case "session.status": {
          const status = props.status as { type?: string } | undefined
          const next = status?.type === "busy" || status?.type === "retry"
          if (next !== busy) {
            busy = next
            if (!busy) idleSince = Date.now()
          }
          break
        }
        case "session.idle":
        case "session.error":
          busy = false
          idleSince = Date.now()
          break
        case "todo.updated": {
          const todos = props.todos as Array<{ status?: string }> | undefined
          if (Array.isArray(todos)) {
            openTodos = todos.filter((t) => t.status === "pending" || t.status === "in_progress").length
          }
          break
        }
        case "session.deleted":
          if (id && id === sessionID) {
            clearInterval(timer)
            clearInterval(flush)
            rmSync(instance, { force: true })
          }
          return
      }
      publish()
    },

    // The one thing that can stall an unattended run is a permission prompt, so
    // it gets answered here instead of waiting for a user who is not there.
    "permission.ask": async (input, output) => {
      if (!away) return

      const type = input.type ?? "unknown"
      const pattern = Array.isArray(input.pattern) ? input.pattern.join(" ") : (input.pattern ?? undefined)
      const subject = pattern ? String(pattern) : ""

      let reason: string | null = null
      if (policy.deny.tools.includes(type)) {
        reason = `toolaanvraag '${type}' is niet op afwezig`
      } else if (type === "bash" && subject) {
        const matched = bashDenied(subject, policy)
        if (matched) reason = `commando matcht '${matched}'`
      }

      if (reason) {
        blocked.push({
          at: new Date().toISOString(),
          type,
          pattern: subject || undefined,
          title: input.title || `${type} ${subject}`.trim(),
          reason: policy.deny.reason,
        })
        // Denying is what pushes the item to the end of the todo list: the model
        // gets the refusal, records it as the last item, and moves on.
        output.status = "deny"
        publish(true)
        return
      }

      output.status = "allow"
      publish()
    },

    "tool.execute.after": async (input) => {
      if (!away || input.tool !== "bash") return
      const command = (input.args as { command?: string } | undefined)?.command
      if (!command) return
      done.push({ at: new Date().toISOString(), title: command })
      if (done.length > 200) done.splice(0, done.length - 200)
    },
  }
}

export default LidswitchPlugin
