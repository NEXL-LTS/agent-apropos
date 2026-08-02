require "json"
require "./agent"

module AgentApropos
  module Agents
    # Gemini CLI: its `AfterTool` event is the only one whose output schema
    # supports injecting text back into the model's context
    # (`hookSpecificOutput.additionalContext`) — its `BeforeTool` event can
    # only override tool arguments or block the call. So both
    # `agent-apropos hook pre` (Layer 2) and `agent-apropos hook post`
    # (Layer 3) run there, matched on Gemini's file-editing tools
    # (`write_file`, `replace`); `Hook.pre`'s Layer 2 matching only needs the
    # edited file's path, which `AfterTool`'s payload still carries, so
    # Layer 2 rules still fire — just after the edit rather than before it.
    # `agent-apropos hook pre` also runs matched on `read_file` alone, so
    # Layer 2 can land on the model's first read instead of only once it
    # (mis)writes there. Also points Gemini's configurable context filename
    # at `AGENTS.md`, so Layer 1 needs no symlink the way Claude's CLAUDE.md
    # does.
    class Gemini < Agent
      SETTINGS_RELATIVE = Path[".gemini", "settings.json"]

      # The context filename agent-apropos points Gemini CLI at, so Layer 1
      # reads the same root file Claude Code and OpenCode do without needing
      # a symlink.
      CONTEXT_FILENAME = "AGENTS.md"

      # `--tool gemini` tells the binary which dialect wired the invocation,
      # so `Hook` can label a Cause's layer as read-triggered without parsing
      # `tool_name` itself. The write/edit group and the read-only group
      # (`ensure_read_group`) deliberately share the identical `pre` command
      # — the read/write distinction comes from `Gemini#read?` inspecting the
      # payload at run time, not from which group fired. `_BASE` because
      # `Agent#hook_command` may append `--allow-outside-repo` to each (see
      # `hook_commands`).
      HOOK_PRE_BASE  = "agent-apropos hook pre --tool gemini"
      HOOK_POST_BASE = "agent-apropos hook post --tool gemini"

      # Gemini CLI's hook `timeout` is passed straight to JS `setTimeout()` —
      # milliseconds, not seconds like Claude Code's own hook `timeout`.
      # Using the same literal `10` here previously gave Gemini's AfterTool
      # hooks a 10-*millisecond* budget, well under the ~3-4ms `agent-apropos`
      # itself needs just to spawn — any load at all (e.g. another CLI agent
      # running concurrently) tips it over, so `agent-apropos hook pre`/`post`
      # would intermittently get SIGTERM'd and reported as failed. 10_000ms
      # is the same 10-second intent, expressed in Gemini's own unit.
      HOOK_TIMEOUT = 10_000_i64

      def name : String
        "gemini"
      end

      def read?(payload : Hook::Payload) : Bool
        payload.tool_name == "read_file"
      end

      def config_relative : Path
        SETTINGS_RELATIVE
      end

      def skill_root : Path
        Path[".gemini", "skills"]
      end

      # Check for the Gemini CLI binary and that its AfterTool hook calls
      # both `agent-apropos hook pre` and `agent-apropos hook post`.
      # Advisory only: never fails, so a Gemini-less repo is not penalised.
      protected def hook_check(repo_root : Path, fs : Filesystem, env : Environment) : Check
        unless env.which("gemini")
          return Check.new(:ok, "gemini", "not on PATH; skipped hook check")
        end
        content = fs.read?(repo_root.join(SETTINGS_RELATIVE).to_s)
        return Check.new(:warn, "gemini", ".gemini/settings.json absent; run `agent-apropos init --tool gemini`") unless content

        wired = wired?(content)
        return Check.new(:warn, "gemini", ".gemini/settings.json is not valid JSON") if wired.nil?

        if wired
          Check.new(:ok, "gemini", "AfterTool hook wired")
        else
          Check.new(:warn, "gemini", "AfterTool hook absent; run `agent-apropos init --tool gemini`")
        end
      end

      # Whether any single `AfterTool` group calls both `agent-apropos hook
      # pre` and `agent-apropos hook post`. Returns nil when the settings
      # file is not parseable JSON.
      #
      # Checked per group, not flattened across all of them: Gemini can have
      # a second, read-only group carrying only `agent-apropos hook pre`
      # (see `ensure_read_group`), so a flattened union of commands across
      # every group could see both commands present overall while the
      # write/edit group itself is missing one — e.g. `pre` only in the read
      # group and `post` in the write group, which is a miswire (Layer 2
      # never fires on an edit) that a flattened check can't tell apart from
      # being fully wired. Same principle as
      # docs/conventions/settings-merge-identity.md.
      private def wired?(content : String) : Bool?
        parsed =
          begin
            JSON.parse(content)
          rescue JSON::ParseException
            return nil
          end
        groups = parsed.as_h?.try(&.["hooks"]?).try(&.as_h?).try(&.["AfterTool"]?).try(&.as_a?)
        return false unless groups
        groups.compact_map(&.as_h?).any? do |group|
          commands = (group["hooks"]?.try(&.as_a?) || [] of JSON::Any)
            .compact_map { |hook| hook.as_h?.try(&.["command"]?).try(&.as_s?) }
          commands.any?(&.starts_with?(HOOK_PRE_BASE)) && commands.any?(&.starts_with?(HOOK_POST_BASE))
        end
      end

      protected def config_content(existing : String?, options : Init::Options) : String
        commands = [hook_command(HOOK_PRE_BASE, options), hook_command(HOOK_POST_BASE, options)]
        root = Init.settings_root(existing, ".gemini/settings.json")
        hooks = (root["hooks"]?.try(&.as_h?)).try(&.dup) || {} of String => JSON::Any
        groups = (hooks["AfterTool"]?.try(&.as_a?)).try(&.dup) || [] of JSON::Any
        groups = ensure_group(groups, commands)
        groups = ensure_read_group(groups, commands)
        hooks["AfterTool"] = JSON::Any.new(groups)
        root["hooks"] = JSON::Any.new(hooks)
        root["context"] = merged_context(root["context"]?)
        JSON::Any.new(root).to_pretty_json + "\n"
      end

      # Converge to fully wired even when a prior run (or a hand-edit) left
      # only one of the two commands present: add the missing command(s)
      # into the existing agent-apropos-owned group rather than skipping
      # just because *a* agent-apropos command is already there, so a
      # half-wired repo self-heals on re-run instead of needing a manual
      # JSON edit. Matching stays on the generic "does this group carry an
      # agent-apropos command" predicate (not the matcher) so a user's own
      # customization of the matcher (e.g. widening it to cover another
      # tool) still gets healed in place rather than spawning a second,
      # default-matcher group alongside it.
      #
      # `ensure_read_group`'s read-only group is explicitly excluded, though:
      # it is also agent-apropos-owned and also carries
      # `agent-apropos hook pre`, so the generic predicate alone can't tell
      # the two groups apart — and if it ran first (before this method's own
      # group exists, e.g. from a hand-edit with only that group present),
      # it would be the first match and get "healed" with
      # `agent-apropos hook post` too, wiring Layer 3 onto `read_file` and
      # leaving the intended write/edit group never created.
      private def ensure_group(groups : Array(JSON::Any), commands : Array(String)) : Array(JSON::Any)
        index = groups.index { |group| agent_apropos_group?(group) && !read_group?(group) }
        return groups + [agent_apropos_group(commands)] if index.nil?

        groups = groups.dup
        groups[index] = with_missing_hooks(groups[index], commands)
        groups
      end

      private def read_group?(group : JSON::Any) : Bool
        group.as_h?.try(&.["matcher"]?).try(&.as_s?) == "read_file"
      end

      # Also refreshes an already-present command's `timeout` to the current
      # `hook` shape, not just appends missing ones — so a repo that ran
      # `init` before the ms-vs-seconds timeout fix actually picks it up on
      # the next `init`, instead of staying stuck on the stale value forever
      # (only the delivery mechanism's own healing can fix this; the
      # settings file itself gives no other signal that the value is
      # stale).
      # An entry whose command matches `commands` exactly is refreshed in
      # place; one that merely *starts with* our prefix — a command string
      # from a prior agent-apropos version, e.g. before a `--tool` suffix
      # existed — is upgraded to the corresponding current command instead of
      # being left as "foreign", so re-running `init` converges an old
      # install onto the new command rather than appending a duplicate.
      private def with_missing_hooks(group : JSON::Any, commands : Array(String)) : JSON::Any
        hash = group.as_h.dup
        refreshed = map_hooks(group) do |entry, command|
          next entry unless command
          target = commands.includes?(command) ? command : upgrade_target(command, commands)
          target ? hook(target) : entry
        end
        present_commands = refreshed.compact_map { |entry| entry.as_h?.try(&.["command"]?).try(&.as_s?) }
        missing = commands.reject { |command| present_commands.includes?(command) }
        hash["hooks"] = JSON::Any.new(refreshed + missing.map { |command| hook(command) })
        JSON::Any.new(hash)
      end

      # The current command that an old, prefix-matching command should
      # converge to, matched on subcommand ("hook pre" vs "hook post") so a
      # stale `hook pre` entry never gets upgraded to `hook post` or
      # vice versa. `nil` for anything that isn't ours at all.
      private def upgrade_target(command : String, desired : Array(String)) : String?
        return nil unless command.starts_with?("agent-apropos hook")
        if command.starts_with?("agent-apropos hook pre")
          desired.find(&.starts_with?("agent-apropos hook pre"))
        elsif command.starts_with?("agent-apropos hook post")
          desired.find(&.starts_with?("agent-apropos hook post"))
        end
      end

      # A second, independent group matched on `read_file` alone, carrying
      # only `agent-apropos hook pre` — kept separate from `ensure_group`'s
      # write_file|replace group (rather than reusing its "does *any*
      # agent-apropos command already exist" check) because that check would
      # see `agent-apropos hook pre` already present in the *write* group
      # and never add this one. Matcher-keyed instead: find (or create) the
      # group whose matcher is exactly "read_file", and ensure it has the
      # command — and, same as `with_missing_hooks`, refresh it if already
      # present rather than no-op'ing, so a stale `timeout` here converges
      # too instead of getting stuck forever once the command already
      # exists.
      private def ensure_read_group(groups : Array(JSON::Any), commands : Array(String)) : Array(JSON::Any)
        index = groups.index { |group| read_group?(group) }
        return groups + [read_group(commands[0])] if index.nil?

        groups = groups.dup
        groups[index] = with_missing_read_hook(groups[index], commands[0])
        groups
      end

      # The read-only group's command is always `commands[0]` — the same
      # `pre` command the write/edit group carries. An entry from a prior
      # agent-apropos version (un-suffixed `agent-apropos hook pre`) is
      # upgraded to it rather than left as "foreign", same reasoning as
      # `with_missing_hooks`.
      private def with_missing_read_hook(group : JSON::Any, target : String) : JSON::Any
        hash = group.as_h.dup
        refreshed = map_hooks(group) do |entry, command|
          command && command.starts_with?("agent-apropos hook pre") ? hook(target) : entry
        end
        has_target = refreshed.any? { |entry| entry.as_h?.try(&.["command"]?).try(&.as_s?) == target }
        hash["hooks"] = JSON::Any.new(has_target ? refreshed : refreshed + [hook(target)])
        JSON::Any.new(hash)
      end

      private def read_group(command : String) : JSON::Any
        JSON::Any.new({
          "matcher" => JSON::Any.new("read_file"),
          "hooks"   => JSON::Any.new([hook(command)]),
        })
      end

      # Map each entry of this group's `hooks` array (paired with its parsed
      # `command` string, `nil` when absent) through the block. Shared by
      # `with_missing_hooks` and `with_missing_read_hook`, which both refresh
      # or upgrade entries in a group's `hooks` array the same way.
      private def map_hooks(group : JSON::Any, & : JSON::Any, String? -> JSON::Any) : Array(JSON::Any)
        present = group.as_h["hooks"]?.try(&.as_a?) || [] of JSON::Any
        present.map do |entry|
          yield entry, entry.as_h?.try(&.["command"]?).try(&.as_s?)
        end
      end

      # Add `AGENTS.md` to `context.fileName` (creating it as a one-element
      # array if absent), preserving every other filename a user already
      # listed.
      private def merged_context(existing : JSON::Any?) : JSON::Any
        context = (existing.try(&.as_h?)).try(&.dup) || {} of String => JSON::Any
        names = context["fileName"]?
        list = names.try(&.as_a?) || names.try { |name| [name] } || [] of JSON::Any
        unless list.any? { |name| name.as_s? == CONTEXT_FILENAME }
          list = list + [JSON::Any.new(CONTEXT_FILENAME)]
        end
        context["fileName"] = JSON::Any.new(list)
        JSON::Any.new(context)
      end

      private def agent_apropos_group(commands : Array(String)) : JSON::Any
        JSON::Any.new({
          "matcher" => JSON::Any.new("write_file|replace"),
          "hooks"   => JSON::Any.new(commands.map { |command| hook(command) }),
        })
      end

      private def hook(command : String) : JSON::Any
        JSON::Any.new({
          "type"    => JSON::Any.new("command"),
          "command" => JSON::Any.new(command),
          "timeout" => JSON::Any.new(HOOK_TIMEOUT),
        })
      end
    end
  end
end
