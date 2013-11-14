%% this server provides quality of service for UPD
%%
%% It encapsulated data and functionality to manage a UDP connection with one
%% client. A typical usage scenario is a player process that provides the game-
%% specific logic for this player that has a UDP quality of service process
%% attached.
%%
%% Its purpose is to keep track of which packets the client has seen and
%% to resend important packets that were lost.
%%
%% Assumptions about the protocol:
%% - Every packet has a sequence number
%% - A conversation starts with sequence number 1
%% - Every packet has two pieces of information about the packets
%%   the other side has received
%%  - The sequence number of the packet it has received last
%%  - A bitfield which indicates which packets were received before
%% - Some packets are not essential and loss is tolerable
%% - Some messages are important and need to be resend if not acknowledged
%% - As long as one of the 'important' messages is to be acknowledged,
%%  no further 'important' message can be send


-module(talk).
-behaviour(gen_server).

%% API for player
-export([
        packet/6,
        record/2,
        wait_for_ack/2,
        wait_for_ack/3,
        wait_for_ack/5,
        packet_to_resend/1
    ]).

%% statistics
-export([
        packet_loss/1,
        packets_out_of_order/1
    ]).

%% gen_server callbacks
-export([start/0, start_link/0, stop/1, init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).


%%-ifdef(TEST).
-compile(export_all).
%%-endif.

-record(talk, {
    local_seq                   = 1,
    out_of_order_count          = 0,
    local_seqs_acked            = sets:new(),
    remote_equivalent_seqs      = sets:new(),
    remote_seqs_acked           = [],
    msg_to_be_acked             = undefined,
    next_expected_remote_seq_no = 0,
    event_handler               = undefined
}).

-record(
    msg_to_be_acked,
    {seq_nos, packet, succes_callback,
     resend_callback, resend_delay, resend_timer, resend_count = 0}).

%% ===================================================================
%% public API
%% ===================================================================

start() ->
    start(undefined).

start(EventHandler) ->
    gen_server:start(?MODULE, EventHandler, []).

start_link() ->
    start_link(undefined).

start_link(EventHandler) ->
    gen_server:start_link(?MODULE, EventHandler, []).

stop(Pid) ->
    gen_server:call(Pid, stop).

stop() ->
    stop(?MODULE).

% build a packet
packet(ResourceId, Command, Payload, WaitForAck, Compression, Server) ->
    PayloadCompressed        = talk_protocol:compress(Compression, Payload),
    {SeqNo, {Ack, Bitfield}} = next_seq_no_and_remote_ack(Server),
    EqSeqNo = case WaitForAck of
        true  -> SeqNo;
        false -> 0
    end,
    Header = talk_protocol:encode_header(ResourceId, {SeqNo, EqSeqNo},
        {Ack, Bitfield}, Command, Compression),
    << Header/binary, PayloadCompressed/binary >>.

% this is the main function where we keep track of things.
record(Packet, Server) when is_binary(Packet) ->
    record(talk_protocol:decode_metadata(Packet), Server);

record({{RemoteSeqNo, EquivalenceSeqNo}, {Ack, Bitfield}}, Server) ->
    gen_server:call(Server,
        {record, {{RemoteSeqNo, EquivalenceSeqNo}, {Ack, Bitfield}}}
    ).

% remember a packet for resend
wait_for_ack(Packet, Server) ->
    wait_for_ack(Packet, fun() -> noop end, Server).

wait_for_ack(Packet, SuccessCallback, Server) ->
    wait_for_ack(Packet, SuccessCallback, undefined, undefined, Server).

wait_for_ack(Packet, SuccessCallback, ResendCallback, ResendDelay, Server) ->
    Reply = gen_server:call(
        Server, {wait_for_ack, {Packet, SuccessCallback, ResendCallback, ResendDelay}}),

    case Reply of
        {error, {already_waiting_for_ack, WaitPacket}} ->
            throw({error, {already_waiting_for_ack, WaitPacket}});
        _ ->
            Reply
    end.

next_seq_no_and_remote_ack(Server) ->
    next_seq_no_and_remote_ack(32, Server).

next_seq_no_and_remote_ack(BitfieldLength, Server) ->
    gen_server:call(Server, {next_seq_no_and_remote_ack, BitfieldLength}).

next_seq_no(Server) ->
    {SeqNo, _} = next_seq_no_and_remote_ack(Server),
    SeqNo.

packet_to_resend(Server) ->
    gen_server:call(Server, {packet_to_resend}).

remote_ack(Server) ->
  remote_ack(32, Server).

remote_ack(BitfieldLength, Server) ->
    gen_server:call(Server, {remote_ack, BitfieldLength}).

packet_loss(Server) ->
    gen_server:call(Server, {packet_loss}).

packets_out_of_order(Server) ->
    gen_server:call(Server, {packets_out_of_order}).

%% ===================================================================
%% gen_server callbacks
%% ===================================================================

init(EventHandler) ->
    State = #talk{ event_handler = EventHandler },
    send_event(init, State),
    {ok, State}.

handle_call(
    {record, {{RemoteSeqNo, EquivalentRemoteSeqNo}, {Ack, Bitfield}}},
    _From, State = #talk{ local_seq = LocalSeq})
    when Ack < LocalSeq ->

    RemoteSeqNos      =
        add_remote_seq(RemoteSeqNo, State#talk.remote_seqs_acked),
    InOrder           =
        in_order(RemoteSeqNo, State#talk.next_expected_remote_seq_no),
    SeenEquivalent    =
        is_acknowledged(EquivalentRemoteSeqNo, State#talk.remote_equivalent_seqs),
    RemoteEquivalentSeqs =
        add_remote_equivalent_seq(EquivalentRemoteSeqNo, State#talk.remote_equivalent_seqs),
    NextExpectedSeqNo =
        max(RemoteSeqNo + 1, State#talk.next_expected_remote_seq_no),
    LocalSeqsAcked    =
        local_seqs_acked(Ack, Bitfield, State#talk.local_seqs_acked),
    {MsgToBeAcked, NewLocalSeq, ResendPacket} =
        msg_to_resend(State#talk.msg_to_be_acked, LocalSeq, LocalSeqsAcked, RemoteSeqNos, State),
    OutOfOrderCount   =
        case InOrder of
            true  -> State#talk.out_of_order_count;
            false -> State#talk.out_of_order_count + 1
        end,

    StateNew =
        State#talk{
            local_seq                   = NewLocalSeq,
            remote_seqs_acked           = RemoteSeqNos,
            remote_equivalent_seqs      = RemoteEquivalentSeqs,
            next_expected_remote_seq_no = NextExpectedSeqNo,
            local_seqs_acked            = LocalSeqsAcked,
            msg_to_be_acked             = MsgToBeAcked,
            out_of_order_count          = OutOfOrderCount},

    HandlePacket =
        InOrder andalso not SeenEquivalent,

    {reply, {HandlePacket, ResendPacket}, StateNew};

% we might receive packets which acknowledge packets we never send
% these probably reach us by accident and are ignored
handle_call({record, {_, {Ack, _}}}, _From, State) ->
    send_event({ignore, State#talk.local_seq, Ack}, State),
    {reply, {false, undefined}, State};

handle_call({next_seq_no_and_remote_ack, BitfieldLength}, _From, State) ->
    LocalSeq  = State#talk.local_seq,
    RemoteAck = remote_ack_internal(BitfieldLength, State#talk.remote_seqs_acked),
    {reply, {LocalSeq, RemoteAck}, State#talk{local_seq = LocalSeq + 1}};

handle_call({packet_to_resend}, _From, State) ->
    {ResendPacket, NewState} = packet_to_resend_internal(State),
    {reply, ResendPacket, NewState};

handle_call(
        {wait_for_ack, {Packet, SuccessCallback, ResendCallback, ResendDelay}},
        _From, #talk{msg_to_be_acked = MsgToBeAcked} = State) ->

    send_event({wait_for_ack, Packet}, State),

    {Reply, StateNew} =
        case MsgToBeAcked of
            undefined ->
                ResendTimer = resend_timer(ResendCallback, ResendDelay),
                SeqNo       = talk_protocol:decode_seq_no(Packet),
                {
                    ok,
                    State#talk{msg_to_be_acked =
                        #msg_to_be_acked{
                            packet          = Packet,
                            seq_nos         = sets:from_list([SeqNo]),
                            succes_callback = SuccessCallback,
                            resend_callback = ResendCallback,
                            resend_delay    = ResendDelay,
                            resend_timer    = ResendTimer
                        }
                    }
                };
            #msg_to_be_acked{ packet = WaitForPacket } ->
                {
                    {error, {already_waiting_for_ack, WaitForPacket}},
                    State
                }
        end,
    {reply, Reply, StateNew};

handle_call({remote_ack, BitfieldLength}, _From, State) ->
    {reply, remote_ack_internal(BitfieldLength, State#talk.remote_seqs_acked), State};

handle_call({packet_loss}, _From,
    State = #talk{local_seq = LocalSeq, local_seqs_acked = AckPackages}) ->

    {reply, packet_loss_internal(LocalSeq, AckPackages), State};

handle_call({packets_out_of_order}, _From, State) ->
    {reply, packets_out_of_order_internal(State), State};

handle_call(stop, _From, State) ->
    {stop, normal, stopped, State}.


handle_cast(_Msg, State) ->
    {noreply, State}.

% the timer may trigger during the success callback,
% so we might see an already empty msg_to_be_acked.
handle_info({resend, _}, State = #talk{ msg_to_be_acked = undefined }) ->
    {noreply, State};
handle_info({resend, ResendCallback}, State = #talk{ msg_to_be_acked = MsgToBeAcked }) ->
    {ResendPacket, NewState0} = packet_to_resend_internal(State),
    ResendCallback   = MsgToBeAcked#msg_to_be_acked.resend_callback,
    ResendCallback(ResendPacket),
    NewResendTimer   = resend_timer(
        MsgToBeAcked#msg_to_be_acked.resend_callback, MsgToBeAcked#msg_to_be_acked.resend_delay),
    NewMsgToBeAcked0 = NewState0#talk.msg_to_be_acked,
    NewMsgToBeAcked1 = NewMsgToBeAcked0#msg_to_be_acked{ resend_timer = NewResendTimer },
    NewState1 = NewState0#talk{ msg_to_be_acked = NewMsgToBeAcked1},
    {noreply, NewState1};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% ===================================================================
%% internal functions
%% ===================================================================

resend_timer(undefined, _) ->
    undefined;
resend_timer(ResendCallback, ResendDalay) ->
    erlang:send_after(ResendDalay, self(), {resend, ResendCallback}).

cancel_resend_timer(undefined) ->
    noop;
cancel_resend_timer(Timer) ->
    erlang:cancel_timer(Timer).

packet_to_resend_internal(State = #talk{ remote_seqs_acked = RemoteSeqsAcked,
                           local_seqs_acked = LocalSeqsAcked, local_seq = LocalSeq }) ->

    {MsgToBeAcked, NewLocalSeq, ResendPacket} =
        msg_to_resend(State#talk.msg_to_be_acked, LocalSeq, LocalSeqsAcked, RemoteSeqsAcked, State),
    NewState = #talk{ local_seq = NewLocalSeq, msg_to_be_acked = MsgToBeAcked },
    {ResendPacket, NewState}.

add_remote_equivalent_seq(0, EqSeqs) ->
    EqSeqs;
add_remote_equivalent_seq(EqSeq, EqSeqs) ->
    sets:add_element(EqSeq, EqSeqs).

add_remote_seq(SeqNo, SeqNos) ->
    lists:sublist(
        lists:usort(
            fun(A, B) -> A > B end,
            [SeqNo | SeqNos]
        ),
        33).

remote_ack_internal(BitfieldLength, []) ->
    {0, <<0:BitfieldLength>>};
remote_ack_internal( BitfieldLength, [Latest|RemoteSeqNosRest]) ->
    {Latest, bitfield(Latest - 1, RemoteSeqNosRest, BitfieldLength)}.

packets_out_of_order_internal(#talk{local_seq = 1}) ->
    0.0;
packets_out_of_order_internal(#talk{
    local_seq = LocalSeq,
    out_of_order_count = OutOfOrderCount}) ->
    OutOfOrderCount / (LocalSeq -1).

packet_loss_internal(1, _)->
    0.0;
packet_loss_internal(LocalSeq, AckPackages) ->
    1 -  (sets:size(AckPackages) / (LocalSeq - 1)).

bitfield(_, _, 0) ->
    <<>>;
bitfield(Expected, [], Length) ->
    Rest = bitfield(Expected - 1, [], Length - 1),
    << 0:1, Rest/bitstring>>;
bitfield(Expected, [Expected|SeqRest], Length) ->
    Rest = bitfield(Expected - 1, SeqRest, Length - 1),
    << 1:1, Rest/bitstring >>;
bitfield(Expected, SeqRest, Length) ->
    Rest = bitfield(Expected - 1, SeqRest, Length - 1),
    << 0:1, Rest/bitstring>>.

in_order(SeqNo, NextExpectedSeqNo) ->
    SeqNo >= NextExpectedSeqNo.

local_seqs_acked(StartNo, Bitfield, AckPackages) ->
    sets:union([
        AckPackages,
        sets:from_list(parse_client_seq(StartNo, Bitfield))
    ]).

parse_client_seq(StartNo, Bitfield) ->
    [StartNo|parse_bitfield(StartNo - 1, Bitfield)].

parse_bitfield(SeqNo, << 1:1, Rest/bitstring >>) ->
    [SeqNo|parse_bitfield(SeqNo - 1, Rest)];
parse_bitfield(SeqNo, << 0:1, Rest/bitstring >>) ->
    parse_bitfield(SeqNo - 1, Rest);
parse_bitfield(_, <<>>) ->
    [].

is_acknowledged(SeqNoOrSeqNos, LocalSeqsAcked) ->
    case sets:is_set(SeqNoOrSeqNos) of
        true  -> not sets:is_disjoint(SeqNoOrSeqNos, LocalSeqsAcked);
        false -> sets:is_element(SeqNoOrSeqNos, LocalSeqsAcked)
    end.

msg_to_resend(undefined, LocalSeq, _, _, _) ->
    {undefined, LocalSeq, undefined};
msg_to_resend(MsgToBeAcked = #msg_to_be_acked{
        resend_count       = ResendCount,
        packet             = Packet,
        seq_nos            = SeqNos,
        succes_callback    = SuccessCallback,
        resend_timer       = ResendTimer},
    LocalSeq, LocalSeqsAcked, RemoteSeqsAcked, State) ->

    case is_acknowledged(SeqNos, LocalSeqsAcked) of
        true ->
            send_event({ack, Packet}, State),
            SuccessCallback(),
            cancel_resend_timer(ResendTimer),
            {undefined, LocalSeq, undefined};
        false ->
            {Ack, Bitfield} = remote_ack_internal(32, RemoteSeqsAcked),
            NewPacket = talk_protocol:set_sequence_id_and_ack(LocalSeq, Ack, Bitfield, Packet),
            % we increment the sequence number so it won't be out of order
            % for the receiving side.
            NewLocalSeq = LocalSeq + 1,
            NewSeqNos = sets:add_element(LocalSeq, SeqNos),
            NewMsgToBeAcked       = MsgToBeAcked#msg_to_be_acked{
                    resend_count  = ResendCount + 1,
                    packet        = NewPacket,
                    seq_nos       = NewSeqNos},
            {NewMsgToBeAcked, NewLocalSeq, NewPacket}
    end.

send_event(_,     #talk{ event_handler = undefined }) ->
    noop;
send_event(Event, #talk{ event_handler = EventHandler }) ->
    apply(EventHandler, handle_event, [Event]).
