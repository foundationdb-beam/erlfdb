defmodule Erlfdb.MixProject do
  use Mix.Project

  @script_path Path.join(__DIR__, "rebar.config.script")

  # Evaluate rebar.config.script once at load time. The script already detects
  # Mix vs rebar3 via code:ensure_loaded(rebar_api) and uses Mix.shell() for
  # logging, so it runs correctly in both environments.
  @rebar_config (case :file.script(String.to_charlist(@script_path), [{:CONFIG, []}]) do
                   {:ok, result} ->
                     result

                   {:error, %Mix.Error{} = err} ->
                     raise err

                   {:error, reason} ->
                     Mix.raise("rebar.config.script error: #{inspect(reason)}")
                 end)

  @version (case :file.consult(String.to_charlist(Path.join(__DIR__, "src/erlfdb.app.src"))) do
              {:ok, [{:application, :erlfdb, props}]} ->
                props |> Keyword.fetch!(:vsn) |> List.to_string()

              {:error, reason} ->
                Mix.raise("Failed to read erlfdb.app.src: #{inspect(reason)}")
            end)

  def project do
    [
      app: :erlfdb,
      version: @version,
      language: :erlang,
      compilers: [:erlfdb_nif, :erlang, :app],
      erlc_options: rebar_erl_opts(),
      deps: deps()
    ]
  end

  def rebar_erl_opts do
    :proplists.get_value(:erl_opts, @rebar_config, [])
  end

  defp deps, do: []
end

defmodule Mix.Tasks.Compile.ErlfdbNif do
  use Mix.Task.Compiler

  @impl true
  def run(_args) do
    erl_opts = Erlfdb.MixProject.rebar_erl_opts()

    api_version =
      Enum.find_value(erl_opts, fn
        {:d, :erlfdb_compile_time_api_version, v} -> v
        _ -> nil
      end) || raise "`:erlfdb_compile_time_api_version` not found"

    lib =
      Enum.find_value(erl_opts, fn
        {:d, :erlfdb_compile_time_external_client_library, v} -> List.to_string(v)
        _ -> nil
      end) || raise "`:erlfdb_compile_time_external_client_library` not found"

    lib_dir = Path.dirname(lib)
    include_dir = System.get_env("ERLFDB_INCLUDE_DIR", "/usr/local/include")

    project_root = Mix.Project.project_file() |> Path.dirname()
    priv_dir = Path.join(Mix.Project.app_path(), "priv")
    File.mkdir_p!(priv_dir)

    sources = Path.wildcard(Path.join(project_root, "c_src/*.c"))
    output = Path.join(priv_dir, "erlfdb_nif.so")

    if stale?(sources, output) do
      compile(api_version, include_dir, lib_dir, sources, output)
    else
      {:noop, []}
    end
  end

  defp stale?(sources, output) do
    case File.stat(output) do
      {:error, _} ->
        true

      {:ok, %{mtime: out_mtime}} ->
        Enum.any?(sources, fn src ->
          case File.stat(src) do
            {:ok, %{mtime: src_mtime}} -> src_mtime > out_mtime
            _ -> true
          end
        end)
    end
  end

  defp compile(api_version, include_dir, lib_dir, sources, output) do
    cflags_version =
      if is_integer(api_version),
        do: "-DFDB_API_VERSION=#{api_version}",
        else: "-DFDB_USE_LATEST_API_VERSION=1"

    erts_include = Path.join([:code.root_dir(), "usr", "include"])
    cflags = "-I#{include_dir} -I#{erts_include} -Ic_src/ -g -Wall -Werror #{cflags_version}"

    ldflags =
      case :os.type() do
        {:unix, :darwin} ->
          "-undefined dynamic_lookup -rpath @loader_path -rpath #{lib_dir} -L#{lib_dir} -lfdb_c"

        _ ->
          "-Wl,-rpath,\\$ORIGIN -Wl,-rpath,#{lib_dir} -L#{lib_dir} -lfdb_c"
      end

    cmd = "cc -shared -fPIC #{cflags} #{Enum.join(sources, " ")} -o #{output} #{ldflags}"

    case System.cmd("sh", ["-c", cmd], stderr_to_stdout: true) do
      {_, 0} ->
        {:ok, []}

      {out, code} ->
        Mix.shell().error("===> [erlfdb] NIF compilation failed (exit #{code}):\n#{out}")
        {:error, []}
    end
  end
end
