defmodule Lifx.Client.Server do
  use GenServer
  use Lifx.Protocol.Types

  require Logger

  alias Lifx.Protocol.{FrameHeader, FrameAddress, ProtocolHeader}
  alias Lifx.Protocol.Packet
  alias Lifx.Protocol
  alias Lifx.Device

  @port 56700
  @multicast Application.get_env(:lifx, :multicast)
  @poll_discover_time Application.get_env(:lifx, :poll_discover_time)
  @udp Application.get_env(:lifx, :udp)

  defmodule State do
    @type t :: %__MODULE__{
            udp: port(),
            source: integer(),
            handlers: [{pid(), pid()}],
            devices: [Device.t()]
          }
    defstruct udp: nil,
              source: 0,
              handlers: [],
              devices: []
  end

  @spec start_link() :: {:ok, pid()}
  def start_link do
    GenServer.start_link(__MODULE__, :ok, name: Lifx.Client)
  end

  @spec init(:ok) :: {:ok, State.t()}
  def init(:ok) do
    source = :rand.uniform(4_294_967_295)
    Logger.debug("LIFX Client: #{source}")

    udp_options = [
      :binary,
      {:broadcast, true},
      {:ip, {0, 0, 0, 0}},
      {:reuseaddr, true}
    ]

    {:ok, udp} = @udp.open(0, udp_options)
    Process.send_after(self(), :discover, 0)

    {:ok, %State{source: source, udp: udp}}
  end

  def handle_call(:discover, _from, state) do
    Logger.debug("Running discover on demand.")
    send_discovery_packet(state.source, state.udp)
    {:reply, :ok, state}
  end

  def handle_call({:handler, handler}, {pid, _}, state) do
    Lifx.EventSupervisor.start_handler(handler, pid)
    {:reply, :ok, %{state | :handlers => [{handler, pid} | state.handlers]}}
  end

  def handle_call(:devices, _from, state) do
    {:reply, state.devices, state}
  end

  def handle_info(:discover, state) do
    Logger.debug("Running discover on timer.")
    send_discovery_packet(state.source, state.udp)
    Process.send_after(self(), :discover, @poll_discover_time)
    {:noreply, state}
  end

  def handle_info({:udp, _s, ip, _port, payload}, state) do
    state = process(ip, payload, state)
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {pid_devices, other_devices} =
      Enum.split_with(state.devices, fn device -> device.pid == pid end)

    pid_devices |> Enum.take(-1) |> hd |> notify(:deleted)
    {:noreply, %State{state | devices: other_devices}}
  end

  @spec lookup_device(atom(), State.t()) :: Device.t() | nil
  defp lookup_device(target, state) do
    device_list =
      state.devices
      |> Enum.filter(fn device -> device.id == target end)
      |> Enum.take(-1)

    case device_list do
      [device] -> device
      [] -> nil
    end
  end

  @spec update_device(Device.t(), State.t()) :: State.t()

  defp update_device(%Device{} = device, %State{} = state) do
    notify(device, :updated)

    devices =
      cond do
        Enum.any?(state.devices, fn dev -> dev.id == device.id end) ->
          Enum.map(state.devices, fn d ->
            cond do
              device.id == d.id -> device
              true -> d
            end
          end)

        true ->
          [device | state.devices]
      end

    %State{state | :devices => devices}
  end

  @spec dispatch_packet(Device.t(), Packet.t(), State.t()) :: State.t()

  defp dispatch_packet(%Device{} = device, %Packet{} = packet, %State{} = state) do
    case Device.packet(device, packet) do
      :ok -> nil
      {:error, err} -> Logger.debug("Cannot contact #{device.id}: #{err}.")
    end

    state
  end

  @spec update_device_from_packet(Device.t(), Packet.t(), State.t()) :: State.t()
  defp update_device_from_packet(
         %Device{} = device,
         %Packet{:protocol_header => %ProtocolHeader{:type => @statelabel}} = packet,
         state
       ) do
    %Device{device | label: packet.payload.label}
    |> update_device(state)
  end

  defp update_device_from_packet(
         %Device{} = device,
         %Packet{:protocol_header => %ProtocolHeader{:type => @stategroup}} = packet,
         state
       ) do
    %Device{device | group: packet.payload.group}
    |> update_device(state)
  end

  defp update_device_from_packet(
         %Device{} = device,
         %Packet{:protocol_header => %ProtocolHeader{:type => @statelocation}} = packet,
         state
       ) do
    %Device{device | location: packet.payload.location}
    |> update_device(state)
  end

  defp update_device_from_packet(_device, _packet, state) do
    state
  end

  @spec handle_packet(Packet.t(), tuple(), State.t()) :: State.t()

  defp handle_packet(
         %Packet{:protocol_header => %ProtocolHeader{:type => @stateservice}} = packet,
         ip,
         state
       ) do
    target = packet.frame_address.target
    host = ip
    port = packet.payload.port

    device =
      case lookup_device(target, state) do
        nil ->
          device = %Device{
            id: target,
            pid: nil,
            host: host,
            port: port
          }

          result =
            Lifx.DeviceSupervisor.start_device(
              device,
              state.udp,
              state.source
            )

          case result do
            {:ok, child} ->
              _ref = Process.monitor(child)
              device = %Device{device | pid: child}
              Lifx.Poller.schedule_device(Lifx.Poller, device)
              device

            {:error, error} ->
              IO.inspect(error)
              Logger.error("Cannot start device child process for #{target}: #{inspect(error)}.")

              nil
          end

        device ->
          %Device{device | host: host, port: port}
      end

    case device do
      nil -> state
      device -> update_device(device, state)
    end
  end

  defp handle_packet(%Packet{:frame_address => %FrameAddress{:target => :all}}, _ip, state) do
    state
  end

  defp handle_packet(
         %Packet{:frame_address => %FrameAddress{:target => target}} = packet,
         _ip,
         state
       ) do
    case lookup_device(target, state) do
      nil ->
        Logger.debug("Cannot find device #{target}.")
        state

      device ->
        state = update_device_from_packet(device, packet, state)
        dispatch_packet(device, packet, state)
    end
  end

  @spec process(tuple(), bitstring(), State.t()) :: State.t()
  defp process(ip, payload, state) do
    payload
    |> Protocol.parse_packet()
    |> handle_packet(ip, state)
  end

  @spec send_discovery_packet(integer(), port()) :: :ok | {:error, atom()}
  defp send_discovery_packet(source, udp) do
    @udp.send(
      udp,
      @multicast,
      @port,
      %Packet{
        :frame_header => %FrameHeader{:source => source, :tagged => 1},
        :frame_address => %FrameAddress{:res_required => 1},
        :protocol_header => %ProtocolHeader{:type => @getservice}
      }
      |> Protocol.create_packet()
    )
  end

  @spec notify(Device.t(), :updated | :deleted) :: :ok
  defp notify(%Device{} = device, status) do
    Lifx.EventSupervisor.notify(device, status)
  end
end
