defmodule Crank.Application do
  @moduledoc """
  Crank's OTP application.

  Started automatically when `:crank` is in the host project's `:extra_applications`
  or `:applications` list. Provides:

    * **OTP version guard.** Raises `CRANK_SETUP_002` at boot if the BEAM is
      OTP < 27. `Crank.PurityTrace` requires `:trace.session_create/3` and
      its surrounding session-scoped tracing API, which only exists in OTP 27+.
      Failing fast at boot beats failing deep in a property test.
    * **`Crank.TaskSupervisor`.** A dedicated `Task.Supervisor` used by
      `Crank.Server` Mode B (when `turn_timeout` is configured) to spawn
      worker tasks that can be killed from outside on timeout. Always
      available wherever Crank is loaded; users do not need to add it to
      their own supervision tree.
  """

  use Application

  @minimum_otp_release 27

  @impl true
  def start(_type, _args) do
    :ok = check_otp_version!()

    children = [
      {Task.Supervisor, name: Crank.TaskSupervisor, max_children: 10_000},
      Crank.PurityTrace.Coordinator
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Crank.Supervisor)
  end

  @doc false
  @spec check_otp_version!() :: :ok
  def check_otp_version! do
    actual = otp_release()

    if actual < @minimum_otp_release do
      violation =
        Crank.Errors.build("CRANK_SETUP_002",
          location: %{file: nil, line: nil},
          context: "Crank.Application boot",
          metadata: %{actual_otp: actual, minimum_otp: @minimum_otp_release}
        )

      raise RuntimeError, Crank.Errors.format_pretty(violation)
    else
      :ok
    end
  end

  @doc """
  Returns the running OTP release as an integer.

  Used internally by the version guard; exposed for testing and for
  documentation/diagnostic purposes.
  """
  @spec otp_release() :: non_neg_integer()
  def otp_release do
    :erlang.system_info(:otp_release) |> List.to_string() |> String.to_integer()
  end

  @doc """
  Returns the minimum supported OTP release.
  """
  @spec minimum_otp_release() :: non_neg_integer()
  def minimum_otp_release, do: @minimum_otp_release
end
