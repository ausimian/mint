defmodule HTTP2.IntegrationTest do
  use ExUnit.Case, async: true

  import Mint.HTTP2.TestHelpers

  alias Mint.HTTP2
  alias Mint.HttpBin

  @moduletag :requires_internet_connection

  setup context do
    transport_opts =
      if Mint.Core.Transport.SSL.ssl_version() >= [10, 2] do
        [{:versions, [:"tlsv1.2", :"tlsv1.3"]}]
      else
        []
      end

    case Map.fetch(context, :connect) do
      {:ok, {host, port}} ->
        extra_transport_opts = Map.get(context, :transport_opts, [])

        assert {:ok, %HTTP2{} = conn} =
                 HTTP2.connect(:https, host, port,
                   transport_opts: transport_opts ++ extra_transport_opts
                 )

        [conn: conn]

      :error ->
        []
    end
  end

  test "TCP - h2c prior knowledge" do
    assert {:ok, %HTTP2{} = conn} = HTTP2.connect(:http, HttpBin.host(), HttpBin.h2c_port())

    assert {:ok, %HTTP2{} = conn, ref} = HTTP2.request(conn, "GET", "/", [], nil)

    assert {:ok, %HTTP2{} = conn, responses} = receive_stream(conn)

    assert [{:status, ^ref, status}, {:headers, ^ref, headers} | rest] = responses
    assert {_, [{:done, ^ref}]} = Enum.split_while(rest, &match?({:data, ^ref, _}, &1))

    assert status == 200
    assert is_list(headers)

    assert conn.buffer == ""
    assert HTTP2.open?(conn)
  end

  describe "httpbin.org" do
    @describetag connect: {HttpBin.host(), HttpBin.https_port()},
                 transport_opts: HttpBin.https_transport_opts()

    test "GET /user-agent", %{conn: conn} do
      assert {:ok, %HTTP2{} = conn, req_id} = HTTP2.request(conn, "GET", "/user-agent", [], nil)

      assert {:ok, %HTTP2{} = conn, responses} = receive_stream(conn)

      assert [
               {:status, ^req_id, 200},
               {:headers, ^req_id, headers},
               {:data, ^req_id, data},
               {:done, ^req_id}
             ] = responses

      assert is_list(headers)
      assert data =~ "mint/"

      assert conn.buffer == ""
      assert HTTP2.open?(conn)
    end

    test "GET /image/png", %{conn: conn} do
      assert {:ok, %HTTP2{} = conn, ref} = HTTP2.request(conn, "GET", "/image/png", [], nil)
      assert {:ok, %HTTP2{} = conn, responses} = receive_stream(conn)

      assert [
               {:status, ^ref, 200},
               {:headers, ^ref, headers},
               {:data, ^ref, data1},
               {:data, ^ref, data2},
               {:done, ^ref}
             ] = responses

      assert is_list(headers)
      assert is_binary(data1)
      assert is_binary(data2)

      assert conn.buffer == ""
      assert HTTP2.open?(conn)
    end

    test "ping", %{conn: conn} do
      assert {:ok, %HTTP2{} = conn, ref} = HTTP2.ping(conn)
      assert {:ok, %HTTP2{} = conn, [{:pong, ^ref}]} = receive_stream(conn)
      assert conn.buffer == ""
      assert HTTP2.open?(conn)
    end
  end

  describe "twitter.com" do
    @describetag connect: {"twitter.com", 443}
    @browser_user_agent "Mozilla/5.0 (Macintosh; Intel Mac OS X 11_0_1) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/87.0.4280.88 Safari/537.36"

    test "ping", %{conn: conn} do
      assert {:ok, %HTTP2{} = conn, ref} = HTTP2.ping(conn)
      assert {:ok, %HTTP2{} = conn, [{:pong, ^ref}]} = receive_stream(conn)
      assert conn.buffer == ""
      assert HTTP2.open?(conn)
    end

    test "GET /", %{conn: conn} do
      assert {:ok, %HTTP2{} = conn, ref} =
               HTTP2.request(conn, "GET", "/", [{"user-agent", @browser_user_agent}], nil)

      assert {:ok, %HTTP2{} = conn, responses} = receive_stream(conn)

      assert [{:status, ^ref, status}, {:headers, ^ref, headers} | rest] = responses
      assert status in [200, 301, 302]

      assert {_, [{:done, ^ref}]} = Enum.split_while(rest, &match?({:data, ^ref, _}, &1))

      assert is_list(headers)

      assert conn.buffer == ""
      assert HTTP2.open?(conn)
    end
  end

  describe "facebook.com" do
    @describetag connect: {"facebook.com", 443}

    test "ping", %{conn: conn} do
      assert {:ok, %HTTP2{} = conn, ref} = HTTP2.ping(conn)
      assert {:ok, %HTTP2{} = conn, [{:pong, ^ref}]} = receive_stream(conn)
      assert conn.buffer == ""
      assert HTTP2.open?(conn)
    end

    test "GET /", %{conn: conn} do
      assert {:ok, %HTTP2{} = conn, ref} = HTTP2.request(conn, "GET", "/", [], nil)

      assert {:ok, %HTTP2{} = conn, responses} = receive_stream(conn)

      assert [{:status, ^ref, status}, {:headers, ^ref, headers} | rest] = responses
      assert {_, [{:done, ^ref}]} = Enum.split_while(rest, &match?({:data, ^ref, _}, &1))

      assert status == 301
      assert is_list(headers)

      assert conn.buffer == ""
      assert HTTP2.open?(conn)
    end
  end

  describe "robynthinks.wordpress.com" do
    @describetag connect: {"robynthinks.wordpress.com", 443}

    test "GET /feed/ - regression for #171", %{conn: conn} do
      # Using non-downcased header meant that HPACK wouldn't find it in the
      # static built-in headers table and so it wouldn't encode it correctly.
      headers = [{"If-Modified-Since", "Wed, 26 May 2019 07:43:40 GMT"}]
      assert {:ok, %HTTP2{} = conn, ref} = HTTP2.request(conn, "GET", "/feed/", headers, nil)

      assert {:ok, %HTTP2{} = conn, responses} = receive_stream(conn)

      assert [{:status, ^ref, status}, {:headers, ^ref, _headers} | rest] = responses
      assert {_, [{:done, ^ref}]} = Enum.split_while(rest, &match?({:data, ^ref, _}, &1))

      assert status in [200, 304]

      assert conn.buffer == ""
      assert HTTP2.open?(conn)
    end
  end

  describe "www.shopify.com" do
    @describetag connect: {"www.shopify.com", 443}

    if List.to_integer(:erlang.system_info(:otp_release)) < 23 do
      @tag :skip
    end

    # Informational responses were the issue.s
    # https://github.com/elixir-mint/mint/issues/349
    test "GET / with specific User-Agent header - regression for #349", %{conn: conn} do
      assert %HTTP2{} = conn

      assert {:ok, %HTTP2{} = conn, ref} =
               HTTP2.request(conn, "GET", "/", [{"user-agent", "curl/7.68.0"}], nil)

      assert {:ok, %HTTP2{} = conn, responses} = receive_stream(conn)

      case responses do
        [
          {:status, ^ref, informational_status},
          {:headers, ^ref, informational_headers},
          {:status, ^ref, status},
          {:headers, ^ref, headers}
          | rest
        ] ->
          assert informational_status == 103
          assert {"link", _} = List.keyfind(informational_headers, "link", 0)
          assert status == 200
          assert is_list(headers) and length(headers) > 0

          assert Enum.count(rest, &match?({:data, ^ref, _data}, &1)) >= 1
          assert List.last(rest) == {:done, ref}

        [{:status, ^ref, status}, {:headers, ^ref, headers} | rest] ->
          assert status == 200
          assert is_list(headers) and length(headers) > 0
          assert Enum.count(rest, &match?({:data, ^ref, _data}, &1)) >= 1
          assert List.last(rest) == {:done, ref}

        _other ->
          flunk(
            "Unexpected responses. Expected status + headers + data, or informational " <>
              "response + status + headers + data, got:\n#{inspect(responses, pretty: true)}"
          )
      end

      assert HTTP2.open?(conn)
    end
  end

  describe "manual window management against local caddyhttpbin" do
    # Minimum HTTP/2 window allowed; we keep both the connection and the
    # per-stream window small so the 1 MB body cannot land in one shot —
    # the server must honour our WINDOW_UPDATE frames between chunks.
    @small_window 65_535
    # httpbin caps /bytes/N at 100 KiB, so pick a body that exceeds the
    # configured 65_535-byte window (forcing at least one
    # WINDOW_UPDATE round-trip) but stays under the cap.
    @body_size 100_000

    test "downloads a 100 KB body in chunks, releasing window credit per chunk" do
      assert {:ok, conn} =
               HTTP2.connect(:https, HttpBin.host(), HttpBin.https_port(),
                 transport_opts: HttpBin.https_transport_opts(),
                 mode: :passive,
                 manual_window_management: true,
                 connection_window_size: @small_window,
                 client_settings: [initial_window_size: @small_window]
               )

      assert {:ok, conn, ref} = HTTP2.request(conn, "GET", "/bytes/#{@body_size}", [], nil)

      {conn, %{status: status, body: body, done?: done?}} =
        drain_with_consume(conn, ref)

      assert done?
      assert status == 200
      assert byte_size(body) == @body_size
      assert HTTP2.open?(conn)
    end

    test "server stalls when the connection window hits 0, resumes after consume_window/3" do
      assert {:ok, conn} =
               HTTP2.connect(:https, HttpBin.host(), HttpBin.https_port(),
                 transport_opts: HttpBin.https_transport_opts(),
                 mode: :passive,
                 manual_window_management: true,
                 connection_window_size: @small_window,
                 client_settings: [initial_window_size: @small_window]
               )

      assert {:ok, conn, ref} = HTTP2.request(conn, "GET", "/bytes/#{@body_size}", [], nil)

      # Drain — without consuming — until the connection window is empty.
      # The 1 MB body cannot complete in @small_window bytes, so the
      # server will stop sending exactly at the window boundary.
      {conn, received} = drain_until_window_empty(conn, ref, "")

      assert byte_size(received) > 0
      assert byte_size(received) <= @small_window
      assert conn.receive_window_remaining == 0

      # With the window at 0 and manual mode on, no WINDOW_UPDATE has been
      # emitted. The server should not send another byte — recv must time
      # out.
      assert {:error, conn, %Mint.TransportError{reason: :timeout}, []} =
               HTTP2.recv(conn, 0, 300)

      # Release credit on both axes. The amounts come from what we
      # actually received: per-stream unacked == byte_size(received),
      # connection unacked == byte_size(received).
      assert {:ok, conn} = HTTP2.consume_window(conn, :connection, byte_size(received))
      assert {:ok, conn} = HTTP2.consume_window(conn, {:request, ref}, byte_size(received))

      # Now the server is allowed to send again — recv should return more
      # data within a short timeout (round-trip across loopback).
      assert {:ok, _conn, responses} = HTTP2.recv(conn, 0, 5_000)
      more = data_only(responses, ref)
      assert byte_size(more) > 0
    end

    defp drain_with_consume(conn, ref) do
      drain_with_consume(conn, ref, %{status: nil, headers: nil, body: "", done?: false})
    end

    defp drain_with_consume(conn, _ref, %{done?: true} = acc), do: {conn, acc}

    defp drain_with_consume(conn, ref, acc) do
      assert {:ok, conn, responses} = HTTP2.recv(conn, 0, 10_000)

      {conn, acc} =
        Enum.reduce(responses, {conn, acc}, fn
          {:status, ^ref, status}, {c, a} ->
            {c, %{a | status: status}}

          {:headers, ^ref, headers}, {c, a} ->
            {c, %{a | headers: headers}}

          {:data, ^ref, chunk}, {c, a} ->
            size = byte_size(chunk)

            # An empty DATA frame (sent by some servers to flag END_STREAM
            # with no payload) consumes no flow-control credit, so there
            # is nothing to release.
            c =
              if size > 0 do
                {:ok, c} = HTTP2.consume_window(c, :connection, size)

                case HTTP2.consume_window(c, {:request, ref}, size) do
                  {:ok, c} -> c
                  # End-of-stream may have already closed the stream entry.
                  {:error, c, _} -> c
                end
              else
                c
              end

            {c, %{a | body: a.body <> chunk}}

          {:done, ^ref}, {c, a} ->
            {c, %{a | done?: true}}
        end)

      drain_with_consume(conn, ref, acc)
    end

    defp drain_until_window_empty(conn, ref, body) do
      if conn.receive_window_remaining == 0 do
        {conn, body}
      else
        assert {:ok, conn, responses} = HTTP2.recv(conn, 0, 5_000)
        drain_until_window_empty(conn, ref, body <> data_only(responses, ref))
      end
    end

    defp data_only(responses, ref) do
      responses
      |> Enum.flat_map(fn
        {:data, ^ref, chunk} -> [chunk]
        _ -> []
      end)
      |> IO.iodata_to_binary()
    end
  end

  # TODO: certificate verification; badssl.com does not seem to support HTTP2
end
