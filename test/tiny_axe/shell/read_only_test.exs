defmodule TinyAxe.Shell.ReadOnlyTest do
  use ExUnit.Case, async: true

  alias TinyAxe.Shell.ReadOnly

  doctest ReadOnly

  defp read_only?(line), do: match?({:read_only, _}, ReadOnly.classify(line))

  describe "commands that only look" do
    test "run without asking" do
      for line <- [
            "ls -la",
            "ls ~/Downloads",
            "df -h",
            "du -sh * | sort -h",
            "du -sh ~/code/* 2>/dev/null | sort -rh | head -20",
            "free -h && uptime",
            "uname -a; whoami; id",
            "ps aux --sort=-%mem | head -15",
            "ps aux | grep node",
            "pgrep -a beam",
            "ss -ltnp",
            "lsof -i :4000",
            "netstat -tulpn",
            "ip -br a",
            "ip addr show dev wlan0",
            "ip route get 1.1.1.1",
            "node --version",
            "python3 -V",
            "go version",
            "cargo --version && rustc -V",
            "which node",
            "command -v mise",
            "env",
            "printenv PATH",
            "cat package.json | jq .version",
            "head -n 20 README.md",
            "tail -n 50 log/dev.log",
            "wc -l lib/**/*.ex",
            "grep -rn 'TODO' lib",
            "rg -n --hidden foo",
            "find . -name '*.ex' | wc -l",
            "find . -type f -newer mix.exs -maxdepth 2",
            "fd -e ex",
            "tree -L 2",
            "cut -d: -f1 /etc/passwd | sort | uniq",
            "sort -k2 -n data.txt",
            "uniq -c counts.txt",
            "diff a.txt b.txt",
            "stat mix.exs",
            "file image.png",
            "date +%Y-%m-%d",
            "hostname -I",
            "cd web && ls",
            "cd 'my folder' && ls -1",
            "echo hi 2>&1 | wc -l",
            "ls 2>/dev/null",
            "ls nope > /dev/null 2>&1",
            "ls |& cat",
            "wc -l < README.md",
            "ls # what's here\nwc -l mix.exs",
            "echo '$(rm -rf x)'",
            "echo \"no expansion here\"",
            "ls \\*",
            "sed -n '10,20p' file.txt",
            "sed -n -e '/error/p' log.txt",
            "sed 's/foo/bar/g' a.txt",
            "sed -E 's|a+|b|2;$d' a.txt",
            "journalctl -u ollama -n 50 --no-pager",
            "nvidia-smi",
            "nvidia-smi --query-gpu=memory.used,memory.total --format=csv",
            "ollama list",
            "ollama ps",
            "docker ps -a",
            "mise ls"
          ] do
        assert read_only?(line), "#{inspect(line)}: #{inspect(ReadOnly.classify(line))}"
      end
    end

    test "git for reading" do
      for line <- [
            "git status",
            "git status --short --branch",
            "git log --oneline -10",
            "git log -p -- lib/x.ex",
            "git --no-pager log -5",
            "git -C ~/code/app status",
            "git diff --stat HEAD~3",
            "git show HEAD:mix.exs",
            "git branch",
            "git branch -a",
            "git branch -vv",
            "git branch --list 'feat*'",
            "git branch --contains abc123",
            "git branch --show-current",
            "git remote -v",
            "git remote get-url origin",
            "git tag",
            "git tag -l 'v1*'",
            "git rev-parse --abbrev-ref HEAD",
            "git ls-files | wc -l",
            "git blame -L 1,10 mix.exs",
            "git describe --tags",
            "git stash list",
            "git reflog -5",
            "git worktree list",
            "git config --get user.name",
            "git config --list --show-origin",
            "git --version",
            "git grep -n defmodule"
          ] do
        assert read_only?(line), "#{inspect(line)}: #{inspect(ReadOnly.classify(line))}"
      end
    end

    test "come back as their words" do
      assert {:read_only, [["git", "log", "--format=%h %s"], ["head", "-3"]]} =
               ReadOnly.classify(~s(git log "--format=%h %s" | head -3))

      assert {:read_only, [["ls", "my file"]]} = ReadOnly.classify(~S(ls my\ file))
    end
  end

  describe "anything else asks" do
    test "commands not on the list" do
      for line <- [
            "rm -rf build",
            "touch x",
            "mkdir new",
            "mv a b",
            "cp a b",
            "chmod +x run.sh",
            "npm install",
            "npm ls",
            "mix test",
            "cargo build",
            "make",
            "python3 script.py",
            "node -e 'require(\"fs\").rmSync(\"x\")'",
            "awk '{print $1}' f",
            "tee out.txt",
            "xargs rm",
            "kill 1234",
            "pkill node",
            "curl https://example.com",
            "sh -c 'ls'",
            "bash script.sh",
            "./run.sh",
            "/bin/ls",
            "../bin/tool",
            "sudo ls",
            "exec ls",
            "eval ls",
            "time ls",
            "nohup ls",
            "less file",
            "vim file",
            "[ -f x ]",
            "! ls",
            "{ ls; }"
          ] do
        refute read_only?(line), "#{inspect(line)} counted as read-only"
      end
    end

    test "writing through redirection, here-documents and process substitution" do
      for line <- [
            "ls > out.txt",
            "ls >> out.txt",
            "ls >| out.txt",
            "ls 1>out.txt",
            "ls 2>err.txt",
            "ls &> all.txt",
            "ls &>> all.txt",
            "echo hi >&out.txt",
            "echo hi>out.txt",
            "cat <> file",
            "cat <<EOF\nhi\nEOF",
            "cat <<< 'hi'",
            "diff <(ls a) <(ls b)",
            "ls > >(cat)",
            "ls > /dev/null$(rm x)",
            "cat < $(echo f)"
          ] do
        refute read_only?(line), "#{inspect(line)} counted as read-only"
      end
    end

    test "expansions, substitutions, assignments, subshells and background jobs" do
      for line <- [
            "ls $(rm -rf x)",
            "ls `rm -rf x`",
            "ls \"$(rm -rf x)\"",
            "ls \"`rm x`\"",
            "echo $HOME",
            "echo ${HOME}",
            "echo $((1+1))",
            "echo $'\\x41'",
            "ls \\$(rm x)",
            "FOO=1 ls",
            "GIT_PAGER='rm -rf x' git log",
            "LD_PRELOAD=/tmp/x.so ls",
            "(ls)",
            "ls && (rm x)",
            "ls &",
            "ls & rm x",
            "ls; rm x",
            "ls && rm x",
            "ls || rm x",
            "ls | rm x",
            "ls\nrm x",
            "ls;;",
            "ls |",
            "| ls",
            "ls && && ls",
            "ls 'unclosed",
            "ls \"unclosed",
            "ls `unclosed",
            "ls $(unclosed",
            "ls \\"
          ] do
        refute read_only?(line), "#{inspect(line)} counted as read-only"
      end
    end

    test "flags that write, run programs, delete or never end" do
      for line <- [
            "find . -delete",
            "find . -name x -exec rm {} \\;",
            "find . -execdir rm {} +",
            "find . -ok rm {} \\;",
            "find . -fprint out.txt",
            "find . -fls out.txt",
            "find . \"-exec\" rm {} \\;",
            "find . -e'xec' rm {} \\;",
            "fd -x rm",
            "fd -HX rm",
            "fd --exec rm",
            "fd --exec-batch rm",
            "sort -o out.txt in.txt",
            "sort -nooutput in.txt",
            "sort --output=out.txt in.txt",
            "sort --out=out.txt in.txt",
            "sort --compress-program=sh in.txt",
            "sort * ",
            "sort {-o,out} in.txt",
            "uniq in.txt out.txt",
            "tail -f log.txt",
            "tail -5f log.txt",
            "tail --follow=name log.txt",
            "date -s '2020-01-01'",
            "date --set='2020-01-01'",
            "file -C -m magic",
            "tree -o out.txt",
            "tree -R -H . ",
            "rg --pre=sh x",
            "rg --pre sh x",
            "rg --hostname-bin=sh x",
            "ss -K dst 1.1.1.1",
            "ss --kill",
            "ss -D out.txt",
            "journalctl -f",
            "journalctl --vacuum-time=1d",
            "journalctl --rotate",
            "hostname newname",
            "hostname -F /etc/x",
            "env FOO=1 ls",
            "env rm x",
            "command rm x",
            "nvidia-smi -pm 1",
            "nvidia-smi -dm 0",
            "nvidia-smi -r",
            "ollama rm llama3",
            "ollama run llama3",
            "docker run alpine",
            "docker rm x",
            "mise install node",
            "mise use -g node@22",
            "node --version --eval x",
            "npm version patch",
            "python3 -c 'print(1)'",
            "ip addr add 10.0.0.1/24 dev eth0",
            "ip a a 10.0.0.1/24 dev eth0",
            "ip link set eth0 down",
            "ip route flush all",
            "ip -batch cmds.txt",
            "ip -force addr",
            "ip netns exec x ls",
            "sed -i 's/a/b/' f",
            "sed -i.bak 's/a/b/' f",
            "sed --in-place 's/a/b/' f",
            "sed -n 's/a/b/w out.txt' f",
            "sed 's/a/b/e' f",
            "sed -e 'w out.txt' f",
            "sed -e p -e 'w out.txt' f",
            "sed 'e rm x' f",
            "sed '1r /etc/passwd' f",
            "sed '1a hello' f",
            "sed -f script.sed f",
            "sed --expression='w x' f",
            "sed"
          ] do
        refute read_only?(line), "#{inspect(line)} counted as read-only"
      end
    end

    test "git that changes things, configures itself or runs programs" do
      for line <- [
            "git commit -m x",
            "git push",
            "git pull",
            "git fetch",
            "git checkout main",
            "git switch -c x",
            "git reset --hard",
            "git clean -fdx",
            "git stash",
            "git stash pop",
            "git branch new-branch",
            "git branch -D old",
            "git branch -m a b",
            "git branch --delete old",
            "git branch -r x",
            "git tag v1.0",
            "git tag -d v1.0",
            "git remote add x url",
            "git remote remove origin",
            "git config user.name Me",
            "git config --global user.name Me",
            "git config --unset user.name",
            "git config --list --add x.y z",
            "git reflog expire --all",
            "git worktree add ../x",
            "git submodule update",
            "git -c core.pager=sh log",
            "git -c alias.x='!rm -rf .' x",
            "git --config-env=core.pager=X log",
            "git --exec-path=/tmp log",
            "git -p log",
            "git log --output=x.txt",
            "git log --out=x.txt",
            "git diff --ext-diff",
            "git diff --textconv",
            "git grep -O vim foo",
            "git grep --open-files-in-pager=vim foo",
            "git log -- *.ex",
            "git st",
            "git",
            "git help log"
          ] do
        refute read_only?(line), "#{inspect(line)} counted as read-only"
      end
    end

    test "say why" do
      assert {:changes, "writes to a file (> out.txt)"} = ReadOnly.classify("ls > out.txt")
      assert {:changes, "find -delete can change things"} = ReadOnly.classify("find . -delete")

      assert {:changes, "rm isn't on the list of commands that only look"} =
               ReadOnly.classify("rm x")

      assert {:changes, "uses $… or `…`, which expand when it runs"} =
               ReadOnly.classify("ls $(x)")

      assert {:changes, "runs something in the background (&)"} = ReadOnly.classify("sleep 1 &")
      assert {:changes, "is empty"} = ReadOnly.classify("   ")
    end
  end

  test "all?/1 needs every line read-only, and at least one" do
    assert ReadOnly.all?(["git status", "df -h"])
    refute ReadOnly.all?(["git status", "npm install"])
    refute ReadOnly.all?([])
  end

  test "parse/1 keeps substitutions for whoever needs them" do
    assert {:ok, [%{words: [%{text: "kill"}, %{expansions: [{:subst, "lsof -t -i:4000"}]}]}]} =
             ReadOnly.parse("kill $(lsof -t -i:4000)")

    assert {:ok,
            [%{words: [_, _]}, %{joined_by: "|", words: [%{text: "xargs"}, %{text: "kill"}]}]} =
             ReadOnly.parse("pgrep node | xargs kill")
  end
end
