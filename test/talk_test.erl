-module(talk_test).

-compile(export_all).

-include("talk_protocol.hrl").

% Include etest's assertion macros.
-include_lib("etest/include/etest.hrl").

before_test() ->
    meck:new(dummy_mod, [non_strict]),
    meck:new(gen_udp, [unstick, passthrough]).

after_test() ->
    meck:unload(dummy_mod),
    meck:unload(gen_udp).

test_packet_building() ->
    {ok, Server} = talk:start(),
    Packet = talk:packet(123, 7, <<"payload">>, true, ?ZipCompression, Server),
    CommandData = talk_protocol:decode_command_data(Packet),
    ?assert_equal({123, 7, <<"payload">>}, CommandData).

test_ack_parsing() ->
    ?assert_equal(
        [123],
        sets:to_list(talk:local_seqs_acked(123, << 0:32 >>, sets:new()))
    ),
    ?assert_equal(
        [123, 122],
        sets:to_list(talk:local_seqs_acked(123, << 1:1, 0:31 >>, sets:new()))
    ),
    ?assert_equal(
        sets:from_list([123, 110, 109, 108, 107, 103, 102, 101]),
        talk:local_seqs_acked(123, << 0:12, 15:4, 0:3, 7:3, 0:10 >>, sets:new())
    ),
    ?assert_equal(
        sets:from_list([123, 110, 109, 108, 107, 103, 102, 101, 7]),
        talk:local_seqs_acked(123, << 0:12, 15:4, 0:3, 7:3, 0:10 >>, sets:from_list([7, 109]))
    ).


test_packet_loss() ->
    Call = fun(LocalSeq, AckPackages) ->
        talk:packet_loss_internal(
            LocalSeq, sets:from_list(AckPackages))
    end,
    ?assert_equal(0.0, Call(1, [])),
    ?assert_equal(0.0, Call(4, [1, 2, 3])),
    ?assert_equal(1-(4/6), Call(7, [1, 3, 4, 5])).


test_resends_unacknowledged_packets() ->
    Ref = make_ref(),
    Me  = self(),
    meck:expect(gen_udp, send, fun(_, _, _, OutgoingPacket) ->
            Me ! {Ref, OutgoingPacket},
            ok
        end),
    Packet = packet(1, 1),
    {ok, Server} = talk:start(),
    ok = talk:wait_for_ack(
        Packet,
        fun() -> dummy_mod:call() end,
        Server
    ),

    {true, P1} = talk:record(
        {{0, 0}, {0, <<0:32>>}},
        Server),
    maybe_resend(P1),
    wait_for_seq({1, 1}, Ref),
    {true, P2} = talk:record(
        {{2, 2}, {0, <<0:32>>}},
        Server),
    maybe_resend(P2),
    wait_for_seq({2, 1}, Ref),
    {true, P3} = talk:record(
        {{3, 3}, {0, <<0:32>>}},
        Server),
    maybe_resend(P3),
    wait_for_seq({3, 1}, Ref).

test_resend_packet() ->
    {ok, Server} = talk:start(),
    SeqNo = talk:next_seq_no(Server),
    Packet =
    talk_protocol:encode_header(123, {SeqNo, SeqNo}, {0, <<0:32>>}, 1, 0),
    ?assert_equal({123, {1, 1}, {0, <<0,0,0,0>>}, 1, 0},
                  talk_protocol:decode_header(Packet)),
    ?assert_equal(undefined, talk:packet_to_resend(Server)),
    ok = talk:wait_for_ack(
        Packet,
        fun() -> dummy_mod:call() end,
        Server
    ),
    ?assert_equal({123, {2, 1}, {0,<<0,0,0,0>>}, 1, 0},
                  talk_protocol:decode_header(talk:packet_to_resend(Server))),
    ?assert_equal({123, {3, 1}, {0,<<0,0,0,0>>}, 1, 0},
                  talk_protocol:decode_header(talk:packet_to_resend(Server))).

maybe_resend(undefined) ->
    noop;
maybe_resend(Packet) ->
    ok = gen_udp:send('_', '_', '_', Packet).

test_acking_resend_messages() ->
    {ok, Server} = talk:start(),
    {true, _} = talk:record(
        {{7, 3}, {0, <<0:32>>}},
        Server),
    ?assert_equal({7, <<0,0,0,0>>}, talk:remote_ack(Server)),
    {false, _} = talk:record(
        {{8, 3}, {0, <<0:32>>}},
        Server),
    ?assert_equal({8, << 1:1, 0:31 >> }, talk:remote_ack(Server)).


wait_for_seq(ExpectedSeq, Ref) ->
    {ActualSeq, Packet} =
    receive
        {Ref, P} ->
            {Seq, _} = talk_protocol:decode_metadata(P),
            {Seq, P}
    after 100 ->
        throw(timeout)
    end,
    ?assert_equal(ExpectedSeq, ActualSeq),
    Packet.

test_dont_handle_out_of_order_packets() ->
    {ok, Server} = talk:start(),
    Call = fun(Seq) ->
        {Handle, _} = talk:record(
            {{Seq, 0}, {0, <<>>}}, Server),
        Handle
    end,
    %% say we sent 3 packages already
    [talk:next_seq_no(Server)||_<-lists:seq(1, 3)],
    HandlePacket1 = Call(2),
    ?assert_equal(true, HandlePacket1),
    HandlePacket2 = Call(3),
    ?assert_equal(true, HandlePacket2),
    ?assert_equal(0.0, talk:packets_out_of_order(Server)),
    HandlePacket3 = Call(1),
    ?assert_equal(false, HandlePacket3),
    ?assert_equal((1/3), talk:packets_out_of_order(Server)).


test_accept_zero_ack() ->
    {ok, Server} = talk:start(),
    {HandlePacket, _} =
        talk:record(
            {{0, 0}, {0, <<>>}}, Server),
    ?assert(HandlePacket).


test_series_of_acks() ->
    {ok, Server} = talk:start(),

    Call = fun(Packet) ->
        % we need to make it increment the internal seequence number
        % so it will accept the replies
        talk:next_seq_no(Server),
        {Handle, _} = talk:record(
            talk_protocol:decode_metadata(Packet),
            Server
        ),
        Handle
    end,
    %              |UserId                     |Seq     |EqSeq  |A|Bitfield
    PacketA = <<96,0,0,179,244,221,146,181,123,0,0,0,1, 0,0,0,0,0,0,0,1,0,0,0,3,1>>,
    PacketB = <<96,0,0,179,244,221,146,181,123,0,0,0,2 ,0,0,0,0,0,0,0,2,0,0,0,3,1>>,
    PacketC = <<96,0,0,179,244,221,146,181,123,0,0,0,3 ,0,0,0,0,0,0,0,3,0,0,0,7,1>>,
    PacketX = <<96,0,0,179,244,221,146,181,123,0,0,0,99,0,0,0,0,0,0,0,99,0,0,0,7,1>>,

    ?assert(Call(PacketA)),
    ?assert(Call(PacketB)),
    ?assert(Call(PacketC)),
    ?assert_not(Call(PacketX)),
    ?assert_not(Call(PacketA)),
    ?assert_not(Call(PacketB)).


test_in_order() ->
    ?assert_equal(true,  talk:in_order(10, 0)),
    ?assert_equal(true, talk:in_order(6,  5)),
    ?assert_equal(true, talk:in_order(5,  5)),
    ?assert_equal(false, talk:in_order(4,  5)),
    ?assert_equal(false, talk:in_order(1,  5)).


test_next_seq_no() ->
    {ok, Server} = talk:start(),
    Seq1 = talk:next_seq_no(Server),
    ?assert_equal(Seq1, 1),
    Seq2 = talk:next_seq_no(Server),
    ?assert_equal(Seq2, 2),
    Seq3= talk:next_seq_no(Server),
    ?assert_equal(Seq3, 3).


test_can_only_wait_for_one_ack_ack() ->
    {ok, Server} = talk:start(),
    NoOp = fun() -> noop end,
    Ping = packet(1, 42),
    Reply1 = talk:wait_for_ack(Ping, NoOp, Server),
    ?assert_equal(ok, Reply1),

    ?assert_throw(
        {error, {already_waiting_for_ack, Ping}},
        talk:wait_for_ack(packet(1, 47), NoOp, Server)
    ).

test_calls_callback_when_acked() ->
    {ok, Server} = talk:start(),
    meck:expect(dummy_mod, call, fun() -> noop end),
    DummyFun = fun() -> dummy_mod:call() end,
    talk:next_seq_no(Server),
    talk:wait_for_ack(packet(42, 1), DummyFun, Server),
    talk:record(
        {{0, 0}, {1, <<>>}},
        Server),
    CallCount = meck:num_calls(dummy_mod, call, []),
    ?assert_equal(1, CallCount).

test_calls_callback_when_resending() ->
    {ok, Server} = talk:start(),
    Self = self(),
    Ref = make_ref(),

    ResendCallback = fun(Packet) ->
        SeqNo = talk_protocol:decode_seq_no(Packet),
        Self ! {Ref, {resend, SeqNo}}
    end,

    SuccessCallback = fun() ->
        Self ! {Ref, success}
    end,

    WaitForResend = fun() ->
        receive
            {Ref, {resend, SeqNo}} -> SeqNo
        after 10 ->
            timeout
        end
    end,

    WaitForSuccess = fun() ->
        receive
            {Ref, success} -> true
        after 10 ->
            timeout
        end
    end,

    SeqNo = talk:next_seq_no(Server),
    Packet =
    talk_protocol:encode_header(123, {SeqNo, SeqNo}, {0, <<0:32>>}, 1, 0),
    ok = talk:wait_for_ack(
        Packet,
        SuccessCallback,
        ResendCallback,
        1,
        Server
    ),

    ?assert_equal(2, WaitForResend()),
    ?assert_equal(3, WaitForResend()),
    ?assert_equal(4, WaitForResend()),
    talk:record(
        {{1, 0}, {3, <<>>}},
        Server),
    ?assert_equal(true, WaitForSuccess()),
    ?assert_equal(timeout, WaitForResend()).


test_bitfield() ->
    BF = fun(Exp, Seqs, Length) ->
        talk:bitfield(Exp, Seqs, Length)
    end,
    ?assert_equal(<<1:1>>,              BF(17, [17], 1)),
    ?assert_equal(<<0:1, 0:1>>,         BF(17, [], 2)),
    ?assert_equal(<<0:1>>,              BF(17, [13], 1)),
    ?assert_equal(<<0:1, 1:1, 0:1>>,    BF(18, [17, 15, 14], 3)),
    ?assert_equal(<<0:1, 1:1>>,         BF(18, [17, 15, 14], 2)).


test_remote_ack() ->
    {ok, Server} = talk:start(),
    AddRemoteSeq = fun(SeqNo) ->
        talk:record({{SeqNo, 0}, {0, <<>>}}, Server)
    end,
    [AddRemoteSeq(S)||S<-[18, 17, 16, 13]],
    ?assert_equal(
        {18, << 1:1, 1:1, 0:1, 0:1, 1:1, 0:1, 0:1, 0:1>>},
        talk:remote_ack(8, Server)
    ).

test_conversation1() ->
    {ok, S1} = talk:start(),
    {ok, S2} = talk:start(),

    send_from_to(S1, S2, false),
    send_from_to(S1, S2, false),
    send_from_to(S2, S1, false),

    ?assert_equal([1],    ack(S1)),
    ?assert_equal([2, 1], ack(S2)),

    % message gets lost
    send_with(S1, true),
    {_, {_, ResendPacket}} = send_from_to(S2, S1, false),
    ?assert_equal([2, 1], ack(S2)),
    receive_with(S2, ResendPacket),
    ?assert_equal([4, 2, 1], ack(S2)),
    send_from_to(S2, S1, false),
    ?assert_equal([3, 2, 1], ack(S1)).


test_conversation2() ->
    {ok, S1} = talk:start(),
    {ok, S2} = talk:start(),


    send_from_to(S1, S2, true),
    [send_from_to(S1, S2, false) || _<- lists:seq(1, 100)],
    ?assert_equal(lists:reverse(lists:seq(69, 101)), ack(S2)),
    send_from_to(S1, S2, false),
    ?assert_equal(lists:reverse(lists:seq(70, 102)), ack(S2)),
    {_, {_, ResendPacket0 }} = send_from_to(S2, S1, false),
    ?assert(ResendPacket0 =/= undefined),
    {_, {SeqNoResend, EqSeqNoResend}, {AckResend, _}, _, _} =
        talk_protocol:decode_header(ResendPacket0),
    ?assert_equal(103, SeqNoResend),
    ?assert_equal(1, EqSeqNoResend),
    ?assert_equal(1, AckResend),
    {Handle, _} = receive_with(S2, ResendPacket0),
    ?assert_equal(false, Handle),
    ?assert_equal(lists:reverse(lists:seq(71, 103)), ack(S2)),
    {_, {_, ResendPacket1}} = send_from_to(S2, S1, false),
    ?assert_equal(undefined, ResendPacket1).

send_with(Server, WaitForack) ->
        SeqNo = talk:next_seq_no(Server),
        {Ack, Bitfield} = talk:remote_ack(Server),
        EqSeqNo = case WaitForack of
                        true  -> SeqNo;
                        false -> 0
                    end,
        Packet = talk_protocol:encode_header(1, {SeqNo, EqSeqNo}, {Ack, Bitfield}, 1, ?NoCompression),
        case WaitForack of
            true  ->
                    talk:wait_for_ack(Packet, fun() -> noop end, Server);
            false ->
                noop
        end,
        Packet.

receive_with(Server, Packet) ->
        talk:record(
            talk_protocol:decode_metadata(Packet), Server).

send_from_to(ServerSend, ServerReceive, WaitForack) ->
        Packet                 = send_with(ServerSend, WaitForack),
        {Handle, ResendPacket} = receive_with(ServerReceive, Packet),
        {Packet, {Handle, ResendPacket}}.

ack(Server) ->
        {Ack, BS} = talk:remote_ack(Server),
        talk:parse_client_seq(Ack, BS).


test_parse_client_seq() ->
    ?assert_equal([1], talk:parse_client_seq(1, <<0:32>>)),
    Str0 = 2#11111111111111111111111111111111,
    ?assert_equal(lists:reverse(lists:seq(1, 33)), talk:parse_client_seq(33, << Str0:32 >>)).

test_set_sequence_id_ack() ->
    Header = talk_protocol:encode_header(123, {1, 1}, {11, <<0:32>>}, 7, ?ZipCompression),
    Payload = <<"this is my payload">>,
    Packet = talk_protocol:assemble_packet(Header, Payload),
    RewrittenPacket = talk_protocol:set_sequence_id_and_ack(2, 12, <<1:32>>, Packet),
    ?assert_equal({123, {2, 1}, {12, <<1:32>>}, 7, ?ZipCompression},
        talk_protocol:decode_header(RewrittenPacket)),
    ?assert_equal({123, 7, <<"this is my payload">>},
                   talk_protocol:decode_command_data(RewrittenPacket)).


packet(UserId, SeqNo) ->
    talk_protocol:encode_header(UserId, {SeqNo, SeqNo}, {1, << 0:32/integer >>}, 0, ?NoCompression).

