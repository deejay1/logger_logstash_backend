################################################################################
# Copyright 2015 Marcelo Gornstein <marcelog@gmail.com>
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
################################################################################
defmodule LoggerLogstashBackend do
  @behaviour :gen_event
  use Timex

  def init({__MODULE__, name}) do
    {:ok, configure(name, [])}
  end

  def handle_call({:configure, opts}, %{name: name}) do
    {:ok, :ok, configure(name, opts)}
  end

  def handle_info(_, state) do
    {:ok, state}
  end

  def handle_event(:flush, state) do
    {:ok, state}
  end

  def handle_event(
    {level, _gl, {Logger, msg, ts, md}}, %{level: min_level} = state
  ) do
    if is_nil(min_level) or Logger.compare_levels(level, min_level) != :lt do
      log_event level, msg, ts, md, state
    end
    {:ok, state}
  end

  def code_change(_old_vsn, state, _extra) do
    {:ok, state}
  end

  def terminate(_reason, %{socket: socket, handler: handler}) do
    handler.close(socket)
    :ok
  end

  defp log_event(
    level, msg, ts, md, %{
      host: host,
      port: port,
      type: type,
      metadata: metadata,
      socket: socket,
      handler: handler
    }
  ) do
    fields = md
             |> Keyword.merge(metadata)
             |> Enum.map(fn({key, value}) -> {key, transform_map_to_string(value)} end)
             |> Enum.into(%{})
             |> Map.put(:level, to_string(level))
             |> inspect_pids

    {{year, month, day}, {hour, minute, second, milliseconds}} = ts
    {:ok, ts} = NaiveDateTime.new(
      year, month, day, hour, minute, second, (milliseconds * 1000)
    )

    timestamp = try do
      ts
      |> Timex.to_datetime(Timezone.local)
      |> Timex.format!("{ISO:Extended}")
    rescue
      ArgumentError ->
        Timex.local
        |> Timex.format!("{ISO:Extended}")
    end
    {:ok, json} = %{
      type: type,
      "@timestamp": timestamp,
      message: to_string(msg),
    }
    |> Map.merge(fields)
    |> JSX.encode()

    handler.send(socket, %{host: host, port: port, payload: json})
  end

  defp configure(name, opts) do
    env = Application.get_env :logger, name, []
    opts = Keyword.merge env, opts
    Application.put_env :logger, name, opts

    level = Keyword.get opts, :level, :debug
    metadata = Keyword.get opts, :metadata, []
    type = Keyword.get opts, :type, "elixir"
    host = Keyword.get opts, :host
    port = Keyword.get opts, :port, 0
    handler = Keyword.get opts, :handler, LoggerLogstashBackend.UDP
    {:ok, socket} = handler.connect(host, port)
    %{
      name: name,
      handler: handler,
      host: host,
      port: port,
      level: level,
      socket: socket,
      type: type,
      metadata: metadata
    }
  end

  # inspects the argument only if it is a pid
  defp inspect_pid(pid) when is_pid(pid), do: inspect(pid)
  defp inspect_pid(other), do: other

  # inspects the field values only if they are pids
  defp inspect_pids(fields) when is_map(fields) do
    Enum.into fields, %{}, fn {key, value} ->
      {key, inspect_pid(value)}
    end
  end

  defp transform_map_to_string(value) do
    with true <- is_map(value) do
      {:ok, string_value} = value
      |> JSX.encode
      string_value
    else
      false -> value
    end
  end
end
