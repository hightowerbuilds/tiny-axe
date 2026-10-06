defmodule TinyAxe.Ops.Fingerprint do
  @moduledoc """
  Fingerprints used by stale-write checks and undo records.
  File hashes keep their original SHA-256 format. New directory hashes are
  tagged tree-v1 and cover names, entry types, contents, and symlink targets.
  Symlinks are never followed. Legacy directory records cannot establish that
  contents are unchanged, so recovery preserves those folders.
  """

  @chunk_bytes 64 * 1024

  @doc "Hex SHA-256 of a string."
  @spec hash(String.t()) :: String.t()
  def hash(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  @doc "Fingerprints a file, directory tree, or symlink; nil if missing."
  @spec path(String.t()) :: String.t() | nil
  def path(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular}} ->
        path
        |> File.stream!(@chunk_bytes)
        |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
        |> :crypto.hash_final()
        |> Base.encode16(case: :lower)

      {:ok, %{type: :directory}} ->
        tree(path)

      {:ok, %{type: :symlink}} ->
        "link-v1:" <> hash(File.read_link!(path))

      {:error, :enoent} ->
        nil

      {:error, reason} ->
        raise File.Error, reason: reason, action: "fingerprint", path: path

      {:ok, _special_file} ->
        raise File.Error, reason: :enotsup, action: "fingerprint", path: path
    end
  end

  @doc "Whether a saved fingerprint can establish that the path is unchanged."
  @spec matches?(String.t(), String.t() | nil) :: boolean()
  def matches?(path, digest) when is_binary(digest) do
    path(path) == digest
  rescue
    File.Error -> false
  end

  def matches?(_path, _digest), do: false

  @doc "Whether the record predates content-aware directory fingerprints."
  @spec legacy_directory?(String.t(), term()) :: boolean()
  def legacy_directory?(path, digest) when is_binary(digest) do
    digest =~ ~r/\A[0-9a-f]{64}\z/ and match?({:ok, %{type: :directory}}, File.lstat(path))
  end

  def legacy_directory?(_path, _digest), do: false

  defp tree(dir) do
    digest =
      dir
      |> File.ls!()
      |> Enum.sort()
      |> Enum.reduce(:crypto.hash_init(:sha256), fn name, hash ->
        child = Path.join(dir, name)
        digest = path(child)

        if digest == nil,
          do: raise(File.Error, reason: :enoent, action: "fingerprint", path: child)

        # Length prefixes make filenames containing separators or newlines
        # unambiguous. Child tags distinguish files, directories, and links.
        :crypto.hash_update(hash, [
          <<byte_size(name)::64>>,
          name,
          <<byte_size(digest)::64>>,
          digest
        ])
      end)
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    "tree-v1:" <> digest
  end
end
