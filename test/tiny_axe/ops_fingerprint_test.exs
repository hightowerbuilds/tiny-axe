defmodule TinyAxe.OpsFingerprintTest do
  use ExUnit.Case, async: true

  alias TinyAxe.Ops.Fingerprint

  @moduletag :tmp_dir

  test "streamed file hashes match existing journal hashes across chunk boundaries", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "data")

    for bytes <- [0, 1, 65_535, 65_536, 65_537, 4_194_307] do
      content = :binary.copy(<<0, 255, 13, 10>>, div(bytes, 4) + 1) |> binary_part(0, bytes)
      File.write!(path, content)
      expected = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

      assert Fingerprint.path(path) == expected
      assert TinyAxe.Ops.hash(content) == expected
    end
  end

  test "directory fingerprints include file contents, hidden entries, and empty folders", %{
    tmp_dir: dir
  } do
    File.mkdir_p!(Path.join(dir, "nested"))
    File.write!(Path.join(dir, ".hidden"), "hidden")
    File.write!(Path.join(dir, "nested/file"), "contents")

    original = Fingerprint.path(dir)
    assert "tree-v1:" <> _ = original
    File.write!(Path.join(dir, "nested/file"), "modified")
    refute Fingerprint.path(dir) == original
    File.write!(Path.join(dir, "nested/file"), "contents")
    assert Fingerprint.path(dir) == original
    File.write!(Path.join(dir, ".hidden"), "edited")
    refute Fingerprint.path(dir) == original
    File.write!(Path.join(dir, ".hidden"), "hidden")
    File.mkdir!(Path.join(dir, "empty"))
    refute Fingerprint.path(dir) == original
    assert Fingerprint.path(Path.join(dir, "missing")) == nil
  end

  test "symlinks fingerprint their targets without following them, including cycles", %{
    tmp_dir: dir
  } do
    tree = Path.join(dir, "tree")
    File.mkdir!(tree)
    target = Path.join(dir, "outside")
    File.write!(target, "one")
    link = Path.join(tree, "link")
    File.ln_s!(target, link)
    File.ln_s!(".", Path.join(tree, "cycle"))
    File.ln_s!("missing", Path.join(tree, "dangling"))
    original = Fingerprint.path(tree)
    File.write!(target, "two")
    assert Fingerprint.path(tree) == original
    File.rm!(link)
    File.ln_s!("another-target", link)
    refute Fingerprint.path(tree) == original
  end

  test "the same tree hashes equally regardless of its location or creation order", %{
    tmp_dir: dir
  } do
    for {name, entries} <- [{"a", ["first", "second"]}, {"b", ["second", "first"]}] do
      File.mkdir!(Path.join(dir, name))
      for entry <- entries, do: File.write!(Path.join([dir, name, entry]), entry)
    end

    assert Fingerprint.path(Path.join(dir, "a")) == Fingerprint.path(Path.join(dir, "b"))
    refute Fingerprint.matches?(Path.join(dir, "missing"), nil)
    refute Fingerprint.matches?(Path.join(dir, "a"), "tree-v2:unknown")
  end
end
