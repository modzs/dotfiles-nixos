#!/usr/bin/env bash
# Behaviour tests for the Neovim plugin declarations.
#
# lua/plugins/ is loaded wholesale by `require('lazy').setup('plugins')`, so a
# file that does not compile, or that returns something other than a table,
# breaks every plugin in the config rather than just itself - and lazy skips it
# and carries on, so nothing else in a run would notice. And lazy.nvim only
# writes a lazy-lock.json entry for a plugin it has actually installed, so a
# spec committed without its pin is invisible until someone clones the repo on
# a new machine and gets a different revision than the author is running.
#
# Neovim itself is the interpreter here, for the same reason the other suites
# use real parsers and a real TOML reader: it is what actually loads these
# files. Which plugins the config declares is a question only lazy can answer -
# its spec grammar has child specs, imports, dependencies and renames - so the
# pin check asks lazy rather than re-deriving the set, and lives in the session
# test below.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

dotfiles_test_parse_args "$@"

NVIM_CONFIG=$ROOT/home/.config/nvim
TMP_ROOT=$(dotfiles_test_tmproot dotfiles-nvim)

# Takes a config directory, prints the number of plugin files it loaded, and
# exits non-zero naming the first one that would not load. Both tests below run
# this same file, one against the repository and one against a fixture, so the
# fixture really does exercise the code the repository check depends on.
LOAD_SCRIPT=$TMP_ROOT/loadable.lua
cat >"$LOAD_SCRIPT" <<'LUA'
local dir = _G.arg[1] .. '/lua/plugins'

local function die(message)
  io.stderr:write(message .. '\n')
  os.exit(1)
end

-- lazy loads the .lua files out of this directory and ignores anything else,
-- so a README or a subdirectory next to the specs must not fail the check.
local files = {}
for _, name in ipairs(vim.fn.readdir(dir)) do
  if name:sub(-4) == '.lua' and vim.fn.filereadable(dir .. '/' .. name) == 1 then
    table.insert(files, name)
  end
end
if #files == 0 then
  die(dir .. ' has no .lua plugin files, so nothing was checked')
end

for _, file in ipairs(files) do
  local chunk, err = loadfile(dir .. '/' .. file)
  if not chunk then
    die('lua/plugins/' .. file .. ' does not compile: ' .. err)
  end
  local ok, value = pcall(chunk)
  if not ok then
    die('lua/plugins/' .. file .. ' errored when loaded: ' .. tostring(value))
  end
  if type(value) ~= 'table' then
    die('lua/plugins/' .. file .. ' returns ' .. type(value) .. ', not a table')
  end
end

io.write(tostring(#files) .. '\n')
LUA

# --- every plugin file loads ---------------------------------------------------
#
# `--clean` keeps the machine's own config out of it, so the suite tests this
# repository and not the user.

test_plugin_files_are_loadable() {
  local status=0 output

  if ! command -v nvim >/dev/null 2>&1; then
    skip "nvim plugin file load check (nvim not found)"
    return 0
  fi

  output=$(nvim --clean -l "$LOAD_SCRIPT" "$NVIM_CONFIG" 2>&1) || status=$?

  if [ "$status" -ne 0 ]; then
    fail "nvim plugin files: $output"
  fi

  pass "nvim: all $output .lua files in lua/plugins/ load and return a table"
}

# --- and a file that does not load is named ------------------------------------
#
# lazy's own behaviour is why this is not left to lazy: given an unparseable
# file in lua/plugins/ it logs the failure, skips the file and carries on, and
# nvim still exits 0. A run that trusted lazy alone would go green with a plugin
# file broken, which is the silent undercoverage this suite exists to prevent.

test_a_file_that_does_not_load_is_named() {
  local fixture plugins status output

  if ! command -v nvim >/dev/null 2>&1; then
    skip "nvim plugin file load failure check (nvim not found)"
    return 0
  fi

  fixture=$TMP_ROOT/fixture
  plugins=$fixture/lua/plugins
  mkdir -p "$plugins" || fail "could not create the plugin file fixture"

  printf "return { 'owner/alpha.nvim' }\n" >"$plugins/good.lua"
  printf 'Not a plugin file.\n' >"$plugins/README.md"

  status=0
  output=$(nvim --clean -l "$LOAD_SCRIPT" "$fixture" 2>&1) || status=$?
  if [ "$status" -ne 0 ]; then
    fail "nvim plugin file check rejected a loadable config: $output"
  fi
  if [ "$output" != "1" ]; then
    fail "nvim plugin file check counted $output files, expected 1 - it must ignore what is not Lua"
  fi

  printf 'this is not lua\n' >"$plugins/broken.lua"
  status=0
  output=$(nvim --clean -l "$LOAD_SCRIPT" "$fixture" 2>&1) || status=$?
  if [ "$status" -eq 0 ]; then
    fail "nvim plugin file check passed a file that does not compile"
  fi
  assert_contains "$output" 'broken.lua' \
    "nvim plugin file check did not name the file that does not compile: $output"
  rm -f "$plugins/broken.lua"

  printf 'return 42\n' >"$plugins/scalar.lua"
  status=0
  output=$(nvim --clean -l "$LOAD_SCRIPT" "$fixture" 2>&1) || status=$?
  if [ "$status" -eq 0 ]; then
    fail "nvim plugin file check passed a file that does not return a table"
  fi
  assert_contains "$output" 'scalar.lua' \
    "nvim plugin file check did not name the file that returns no table: $output"
  rm -f "$plugins/scalar.lua"

  pass "nvim: a plugin file that does not load fails the suite by name"
}

# --- the two markdown plugins work, and lazy's set matches the lock ------------
#
# markdown-preview.nvim defines its three commands with `command! -buffer` from
# its own BufEnter/FileType autocmd, so merely sourcing the plugin gives them to
# no buffer. Declared with `cmd` alone, the first `:MarkdownPreviewToggle` of a
# session loads the plugin, finds no command to hand the invocation to, and
# leaves none behind - lazy has already deleted its own stub, so retyping it
# gives E492. The sibling macOS repo shipped that spec and had to fix it, which
# is why the check drives the real config through lazy and asks for the preview
# the way a user does, rather than reading the spec file: a spec that does not
# work reads the same as one that does.
#
# render-markdown.nvim draws with extmarks, so its marks are the equivalent
# evidence, and they carry a second claim with them: AGENTS.md records that
# nvim-treesitter is deliberately absent because the flake-pinned nvim bundles
# the markdown parsers. Marks on this buffer are that claim holding. The count
# is not asserted - it moves with the sample and with the plugin - only that
# there are any.
#
# The same session answers the pin question. It has already resolved the whole
# spec tree, so `require('lazy').plugins()` is the managed set as lazy itself
# understands it - no second invocation, and nothing here to drift out of step
# with lazy's grammar. The names are compared both ways, and then the
# checked-out revision of every plugin lazy INSTALLS against the commit its lock
# entry names. That last one is not redundant: a pin lazy cannot check out still
# leaves the branch head cloned and installed, so every other assertion here
# passes while the machine runs a revision the repo does not pin - and lazy then
# writes what it actually got over the tracked lock, through the out-of-store
# ~/.config/nvim symlink. lazy.nvim itself is the one plugin lazy does not
# install, and the exemption is explained beside it in the probe.
#
# The orphan half has a cost, accepted rather than overlooked: lazy keeps lock
# entries for disabled plugins on purpose (manage/lock.lua), so that re-enabling
# one restores its pin, while `require('lazy').plugins()` leaves them out. So
# `enabled = false` on any plugin here WILL fail this check. Re-enable it, or
# delete its spec properly - do not answer it by deleting a pin lazy kept.
#
# Every failure below hands over what the run captured. A guard that states a
# cause while discarding its evidence has been wrong here before: the probe can
# die part-written, and then the only honest thing to report is the log.
#
# Installing the plugins needs the network, which puts this in the same class as
# tests/nixpkgs-channel.test.sh: it reports skip, never ok, when it cannot run.
#
# Two boundaries are deliberate. The scratch run neutralises markdown-preview's
# `build` by handing lazy a shell that does nothing: no assertion here depends
# on the built server - mkdp reports a missing one rather than throwing - so
# pulling its npm dependency tree on every run would be cost with no coverage
# behind it. That shell is written here rather than named as a path, because
# neither `/usr/bin/true` nor `/bin/true` is a file this repo may assume: NixOS
# creates only `/bin/sh` and `/usr/bin/env`, and the suite also has to run from
# the Mac this repo is edited on.
# And the network calls are not bounded: that same Mac ships no `timeout`, so
# capping them would mean building a timer inside nvim. CI's job-level timeout
# is the backstop, and a local run can be interrupted.

test_markdown_plugins_and_pins_in_a_real_session() {
  local session config data mkdp evidence
  local outcome exists rendered managed unpinned orphaned lockerror
  local mismatch unreadable norevision

  if ! command -v nvim >/dev/null 2>&1; then
    skip "nvim markdown preview command check (nvim not found)"
    skip "nvim render-markdown extmark check (nvim not found)"
    skip "nvim lazy-lock.json pin check (nvim not found)"
    skip "nvim lazy-lock.json revision check (nvim not found)"
    return 0
  fi
  if ! command -v git >/dev/null 2>&1; then
    skip "nvim markdown preview command check (git not found)"
    skip "nvim render-markdown extmark check (git not found)"
    skip "nvim lazy-lock.json pin check (git not found)"
    skip "nvim lazy-lock.json revision check (git not found)"
    return 0
  fi

  session=$TMP_ROOT/session
  config=$session/config
  data=$session/data
  mkdir -p "$config" "$data" "$session/state" "$session/cache" \
    || fail "could not create the nvim session scratch directories"

  # lazy writes its lock file into stdpath('config'), and installing plugins is
  # exactly what this does, so the config it drives is a copy. The tracked
  # lazy-lock.json is an input here, never an output.
  cp -R "$NVIM_CONFIG" "$config/nvim" || fail "could not copy the nvim config"

  printf '#!/usr/bin/env bash\nexit 0\n' >"$session/noop-shell"
  chmod +x "$session/noop-shell" || fail "could not create the no-op build shell"

  cat >"$session/noop.vim" <<'VIM'
function! MkdpTestNoop(url) abort
endfunction
let g:mkdp_browserfunc = 'MkdpTestNoop'
VIM

  cat >"$session/probe.lua" <<'LUA'
-- `:MarkdownPreviewToggle` as the first command of the session, on a markdown
-- buffer that was already open before it was typed. Both halves are recorded:
-- the invocation can look fine while the command it needed no longer exists.
-- Nothing stops the preview here; the server is a job of this nvim, so quitting
-- takes it down. `:MarkdownPreviewStop` would not - it blocks on an rpcrequest
-- the server never answers when no page has been opened yet.
local out = assert(io.open(os.getenv('NVIM_PROBE_OUT'), 'w'))
local ok = pcall(vim.cmd, 'MarkdownPreviewToggle')
out:write('toggle ' .. tostring(ok) .. ' ' .. tostring(vim.fn.exists(':MarkdownPreviewToggle')) .. '\n')

-- render-markdown places no marks until a render pass runs, and creates its
-- namespace only once loaded, so a missing namespace counts as nothing drawn.
local function drawn()
  local ns = vim.api.nvim_get_namespaces()['render-markdown.nvim']
  if not ns then
    return 0
  end
  return #vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {})
end
vim.cmd('doautocmd BufWinEnter')
vim.wait(5000, function() return drawn() > 0 end, 50)
out:write('rendered ' .. tostring(drawn()) .. '\n')

-- Which plugins the config declares is lazy's answer to give, not this file's:
-- it has just resolved the whole spec tree, imports and child specs included.
local handle, open_err = io.open(os.getenv('NVIM_PROBE_LOCKFILE'), 'r')
if not handle then
  out:write('lockerror lazy-lock.json could not be read: ' .. tostring(open_err) .. '\n')
  out:close()
  return
end
local body = handle:read('*a')
handle:close()
local decoded, lock = pcall(vim.json.decode, body)
if not decoded or type(lock) ~= 'table' then
  out:write('lockerror lazy-lock.json is not valid JSON: ' .. tostring(lock) .. '\n')
  out:close()
  return
end

-- Naming the same plugins is not the same as running the pinned revision: a
-- commit lazy cannot check out leaves the branch head cloned and installed, so
-- the name comparison alone would pass. Ask git what is actually there. Three
-- reads reach into lazy internals - the two modules, and the `lazy.core.config`
-- field the exemption below is built on - so all three are guarded: if any of
-- them moves in a future lazy release, say which, and let the run report an
-- honest skip rather than blame lazy for answering nothing. The field needs its
-- own guard, not just the module load: a `lazy.core.config` that no longer
-- carries `me` would leave the exemption resolving to nil, and lazy.nvim's own
-- revision would then be compared - going red the next time upstream moves the
-- `stable` tag, which is the exact failure the exemption exists to prevent.
local has_git, git = pcall(require, 'lazy.manage.git')
local has_config, lazy_config = pcall(require, 'lazy.core.config')
local no_revisions
if not has_git then
  no_revisions = 'lazy.manage.git could not be required'
elseif not has_config then
  no_revisions = 'lazy.core.config could not be required'
elseif type(lazy_config.me) ~= 'string' then
  no_revisions = 'lazy.core.config.me is not a path, so lazy.nvim could not be exempted'
end
if no_revisions then
  out:write('norevision ' .. no_revisions .. '\n')
end

-- lazy.nvim's own revision is not lazy's to set, so it is exempt from this one
-- comparison: lua/plugin.lua bootstraps it with `--branch=stable`, and
-- Manage.install skips any plugin already installed with no build, so the
-- checkout step never runs for lazy itself. Comparing it would go red the day
-- upstream moves that tag, on a change that touched nothing here. The name
-- comparison below still covers it, in both directions.
local lazy_dir = not no_revisions and lazy_config.me or nil

local managed = {}
local count = 0
for _, plugin in ipairs(require('lazy').plugins()) do
  managed[plugin.name] = true
  count = count + 1
  local pin = lock[plugin.name]
  if pin ~= nil and not no_revisions and plugin.dir ~= lazy_dir then
    local readable, info = pcall(git.info, plugin.dir)
    if not readable or type(info) ~= 'table' or type(info.commit) ~= 'string' then
      out:write('unreadable ' .. plugin.name .. '\n')
    elseif info.commit ~= pin.commit then
      out:write('mismatch ' .. plugin.name .. ' pinned ' .. tostring(pin.commit)
        .. ' but checked out ' .. info.commit .. '\n')
    end
  end
end
out:write('managed ' .. tostring(count) .. '\n')
for name in pairs(managed) do
  if lock[name] == nil then
    out:write('unpinned ' .. name .. '\n')
  end
end
for name in pairs(lock) do
  if not managed[name] then
    out:write('orphaned ' .. name .. '\n')
  end
end
out:close()
LUA

  cat >"$session/note.md" <<'MD'
# Heading

Some **bold** text, then a list:

- one
- two

> a quote

```lua
local x = 1
```

| a | b |
| - | - |
| 1 | 2 |
MD

  env XDG_CONFIG_HOME="$config" XDG_DATA_HOME="$data" XDG_STATE_HOME="$session/state" \
    XDG_CACHE_HOME="$session/cache" SHELL="$session/noop-shell" \
    nvim --headless -c 'quitall!' >"$session/install.log" 2>&1

  # lua/plugin.lua clones lazy.nvim before it asks lazy for anything, so its
  # presence is this run's proof that git and the network worked. Past that
  # point a missing markdown-preview.nvim is a defect in the spec, not an
  # environment this check could not run in.
  mkdp=$data/nvim/lazy/markdown-preview.nvim
  if [ ! -d "$data/nvim/lazy/lazy.nvim" ]; then
    skip "nvim markdown preview command check (lazy.nvim could not be installed)"
    skip "nvim render-markdown extmark check (lazy.nvim could not be installed)"
    skip "nvim lazy-lock.json pin check (lazy.nvim could not be installed)"
    skip "nvim lazy-lock.json revision check (lazy.nvim could not be installed)"
    return 0
  fi

  evidence=$(cat "$session/install.log" 2>/dev/null)
  if [ -z "$evidence" ]; then
    evidence='no output captured'
  fi
  if [ ! -f "$mkdp/plugin/mkdp.vim" ]; then
    fail "nvim markdown preview: lazy installed but markdown-preview.nvim did not - lua/plugins/markdown.lua no longer declares it, or declares it disabled or misnamed. lazy said: $evidence"
  fi

  env XDG_CONFIG_HOME="$config" XDG_DATA_HOME="$data" XDG_STATE_HOME="$session/state" \
    XDG_CACHE_HOME="$session/cache" NVIM_PROBE_OUT="$session/probe.txt" \
    NVIM_PROBE_LOCKFILE="$NVIM_CONFIG/lazy-lock.json" \
    nvim --headless --cmd "source $session/noop.vim" "$session/note.md" \
      -c "luafile $session/probe.lua" -c 'quitall!' >"$session/session.log" 2>&1

  evidence=$(cat "$session/session.log" "$session/probe.txt" 2>/dev/null)
  if [ -z "$evidence" ]; then
    evidence='no output captured'
  fi

  if [ ! -f "$session/probe.txt" ]; then
    fail "nvim session: the session recorded no result: $evidence"
  fi
  outcome=$(awk '$1 == "toggle" { print $2 }' "$session/probe.txt")
  exists=$(awk '$1 == "toggle" { print $3 }' "$session/probe.txt")
  rendered=$(awk '$1 == "rendered" { print $2 }' "$session/probe.txt")
  managed=$(awk '$1 == "managed" { print $2 }' "$session/probe.txt")
  unpinned=$(awk '$1 == "unpinned" { print $2 }' "$session/probe.txt" | tr '\n' ' ')
  orphaned=$(awk '$1 == "orphaned" { print $2 }' "$session/probe.txt" | tr '\n' ' ')
  unreadable=$(awk '$1 == "unreadable" { print $2 }' "$session/probe.txt" | tr '\n' ' ')
  mismatch=$(awk '$1 == "mismatch" { $1 = ""; sub(/^ /, ""); print }' "$session/probe.txt" | tr '\n' ';')
  norevision=$(sed -n 's/^norevision //p' "$session/probe.txt")
  lockerror=$(sed -n 's/^lockerror //p' "$session/probe.txt")

  if [ "$outcome" != "true" ]; then
    fail "nvim markdown preview: :MarkdownPreviewToggle did not run cleanly on a markdown buffer: $evidence"
  fi
  if [ "$exists" != "2" ]; then
    fail "nvim markdown preview: exists(':MarkdownPreviewToggle') is '$exists' after the first invocation, not 2 - mkdp defines its commands buffer-locally from an autocmd, so the spec needs ft = 'markdown' to have them in a buffer that is already open: $evidence"
  fi

  pass "nvim: :MarkdownPreviewToggle runs and survives as the first command of a session"

  if [ -z "$rendered" ] || [ "$rendered" -lt 1 ]; then
    fail "nvim render-markdown: '$rendered' extmarks on a markdown buffer - the plugin drew nothing, so either its spec is gone or the nvim in home.packages no longer bundles the markdown parsers it reads through: $evidence"
  fi

  pass "nvim: render-markdown draws $rendered extmarks with no nvim-treesitter installed"

  if [ -n "$lockerror" ]; then
    fail "nvim pin check: $lockerror"
  fi
  if [ -z "$managed" ] || [ "$managed" -lt 1 ]; then
    fail "nvim pin check: lazy reported no managed plugins: $evidence"
  fi
  if [ -n "$unpinned" ]; then
    fail "nvim pin check: lazy manages these with no lazy-lock.json entry: $unpinned"
  fi
  if [ -n "$orphaned" ]; then
    fail "nvim pin check: lazy-lock.json pins these but lazy manages nothing by that name: $orphaned"
  fi

  pass "nvim: lazy's $managed plugins and lazy-lock.json name the same set"

  # A mismatch that was actually observed is named before anything else: a
  # revision that could not be read elsewhere must not bury a pin violation
  # this run holds in hand.
  if [ -n "$mismatch" ]; then
    fail "nvim pin check: lazy-lock.json is not what got checked out: $mismatch"
  fi
  if [ -n "$norevision" ]; then
    skip "nvim lazy-lock.json revision check ($norevision)"
    return 0
  fi
  if [ -n "$unreadable" ]; then
    skip "nvim lazy-lock.json revision check (no revision could be read for: $unreadable)"
    return 0
  fi

  pass "nvim: every plugin lazy installs is checked out at the revision lazy-lock.json pins"
}

test_plugin_files_are_loadable
test_a_file_that_does_not_load_is_named
test_markdown_plugins_and_pins_in_a_real_session

test_summary 6
