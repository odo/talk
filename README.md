# talk
====

talk is an erlang generic server that does the book keeping around a conversation over UDP.

UDP makes no guarantees about the order of packets or their delivery so this has to be handled by the application.
By not making this guarantees it needs less roundtrips than TCP and is thus much faster.

talk handles packet headers, sequence numbers and acknowledgements for you.
It assumes that your conversation follows a certain pattern:

```
   Important messages  *                *               *       *
 Unimportant messages  .  .  .  .  .  .  .  .  .  .  .  .  .  .  
                      ------------------ time ------------------->
```

_Important messages_ are messages you want to make sure the recipient received, so you wait for acknowledgement and resend it when needed. They can be used to induce and confirm change of state on the other side. You can only have one important message 'in flight' at any time.

_Unimportant messages_ are messages which are not essential (e.g. ping-pong heart beats) or become stale very fast. Think of the temperature of a heater, you would not resend an old measurement. If one packet is lost, just send the current one. 

## Installation


```
git clone git@github.com:odo/talk.git
cd talk
./rebar get-deps compile
```

## Tests

```
./deps/etest/bin/etest-runner
```

## Example

### Setup

We can best see how talk works by simulating a conversation between two parties.

For this we are starting two erlang nodes, "left" and "right".

left                                          |right
----------------------------------------------|---
`erl -pz ebin -sname left`|`erl -pz ebin -sname right`
`{Port, RemotePort} = {5555, 5556}.`|`{Port, RemotePort} = {5556, 5555}.`


__On Both sides:__

```erlang
ResourceId = 0.    % we don't dispatch so we always use the same resource id
HiCmd = 1.         % unimportant chit-chat
PleaseReadCmd = 2. % a super important message
Host = {127, 0, 0, 1}.
{ok, Talk} = talk:start().
{ok, Socket} = gen_udp:open(Port, [binary, {ip, Host}]).

Send = fun(Command, Payload) ->
	PacketOut = talk:packet(ResourceId, Command, Payload, false, 0, Talk),
	gen_udp:send(Socket, Host, RemotePort, PacketOut),
	PacketOut
end.

Recv = fun() ->
    receive
        {udp, _, _, _, PacketIn} ->
			{Handle, ResendPacket} = talk:record(PacketIn, Talk),
			CommandData = talk_protocol:decode_command_data(PacketIn),
            {CommandData, Handle, ResendPacket}
    after 5000 ->
            timeout
	end
end.
```

So we defined two commands, one important one and one not so important, started a talk server and opened a socket.

As you can see, we use talk to build our packets and set all the headers. Likewise when receiving packets, we have to show them to talk so it can see what packets the other side acknowledged and if the packets are in order.   

### Sending non-important messages

So let's send something:

left                                          |right
----------------------------------------------|---
`Send(HiCmd, <<"hello">>).`|-
-|`Recv().`
-|`>> {{0,1,<<"hello">>},true,undefined}`

So what we got is the parsed message with the resource id (`0`) which we ignore, the command (`1 = HiCmd`), and the payload.
Apart from that talk tells us to handle the command and that we don't have a message to resend.
Reasons for not handling a packet could be that it was received out of order or that we saw an equivalent message before. 

### Sending important messages

Next step is to send an important message that requires an action when acknowledged.

__left:__

```erlang
SendImportant = fun(Command, Payload, Callback) ->
	PacketOut = talk:packet(ResourceId, Command, Payload, true, 0, Talk),
	gen_udp:send(Socket, Host, RemotePort, PacketOut),
	talk:wait_for_ack(PacketOut, Callback, Talk)
end.
```

left                                          |right
----------------------------------------------|---
`Callback = fun() -> io:format("Right got the message!\n", []) end.` | -
`SendImportant(PleaseReadCmd, <<"dinner is ready">>, Callback).` | -
- | `Recv().`
- | `>> {{0,2,<<"dinner is ready">>},true,undefined}`
- | `Send(HiCmd, <<"hello back">>).`
`Recv().` | -
`>> Right got the message!` | -
`>> {{0,1,<<"hello back">>},true,undefined}` | -

So after sending our important message like before (except setting WaitForAck to true in `talk:packet/6`), we told talk to notify us of the acknowledgement and print a message.
As soon as the other side sent a message back, the callback was triggered. So in order to have important messages to be acknowledged it is helpful to have some background communication going on, maybe in the form of ping and pong messages been exchanged at a fixed interval.

### Handling packet loss

So what happens if an important message gets lost? To simulate this we provide the right side with a way to sink messages:

__right:__

```erlang
Sink = fun() ->
    receive
        {udp, _, _, _, _} ->
        	noop
    after 5000 ->
            timeout
    end
end.
```

left                                          |right
----------------------------------------------|---
`SendImportant(PleaseReadCmd, <<"dinner is ready">>, Callback).` | -
- | `Sink().`
- | `Send(HiCmd, <<"hello back">>).`
`{_Message, _Handle, ResendPacket} = Recv().` | -
`>> {{0,1,<<"hello back">>},true,<<96,0,0...>>}` | -
- | `{{0,2,<<"dinner is ready">>},false,undefined}`

We can see that after receiving the message, talk on the left side tells us that the other side did not see our important message and hands us a new but equivalent packet which we send.

left                                          |right
----------------------------------------------|---
`gen_udp:send(Socket, Host, RemotePort, ResendPacket).` | -
- | `Recv().`
- | `Send(HiCmd, <<"hello back">>).`
`Recv().` | -
`>> Right got the message!` | -
`>> {{0,1,<<"hello back">>},true,undefined}` | -

### Handling packet crossing

There are situations where left sends an important message and after that receives a message from right which was send before left's message arrived. We can simulate that by delaying the call to `talk:record/2` until after sending.

__right:__

```erlang
RecvRaw = fun() ->
    receive
        {udp, _, _, _, PacketIn} ->
        	PacketIn
    after 5000 ->
            timeout
    end
end.
```

left                                          |right
----------------------------------------------|---
`SendImportant(PleaseReadCmd, <<"dinner is ready">>, Callback).` | -
- | `PacketToProcessLater = RecvRaw().`
- | `Send(HiCmd, <<"hello back">>).`
- | `talk:record(PacketToProcessLater, Talk).`
`{_Message, _Handle, ResendPacket2} = Recv().` | -
`>> {{0,1,<<"hello back">>},true,<<96,0,0,...>>}` | -
`gen_udp:send(Socket, Host, RemotePort, ResendPacket).` | -
- | `Recv().`
- | `{{0,2,<<"dinner is ready">>},false,undefined}`

So what we see is that talk tells right not to process the resent message because it already processed a equivalent one. After that, everything proceeds as expected:

left                                          |right
----------------------------------------------|---
- | `Send(HiCmd, <<"hello back">>).`
`Recv().` | -
`>> Right got the message!` | -
`>> {{0,1,<<"hello back">>},true,undefined}` | -

### Proactive resend

Up till now we only resent packets upon receiving packets. There are situations where you might want to resend periodically without hearing from the other side. An example is [connection termination as done in TCP](https://en.wikipedia.org/wiki/Transmission_Control_Protocol#Connection_termination).

Talk will handle the periodic resend for you so it will not pollute your application code. It does not handle the socket itself but uses a callback you provide. This way it is possible to use a new socket during resend if the old one closed in the meantime.

__left__

```erlang
Resend = fun(Packet) ->
	io:format("resending.\n", []),
	gen_udp:send(Socket, Host, RemotePort, Packet)
end.
SendImportantProactiveResend = fun(Command, Payload, ResendCallback, Callback) ->
    PacketOut = talk:packet(ResourceId, Command, Payload, true, 0, Talk),
    gen_udp:send(Socket, Host, RemotePort, PacketOut),
    talk:wait_for_ack(PacketOut, Callback, ResendCallback, 100, Talk)
end.
```

This will resend the message every 100ms until it gets acknowledged.

left                                          |right
----------------------------------------------|---
`SendImportantProactiveResend(HiCmd, <<"hello back">>, Resend, Callback).` | -
`resending.` | -
`resending.` | -
`resending.` | -
`resending.` | -
… | -
- | `Recv().`
- | `Send(HiCmd, <<"hello back">>)`.
`Recv().` | -
`>> Right got the message!` | -
`>> {{0,1,<<"hello back">>},true,undefined}` | -


### Callbacks for events within the talk server

Apart from callback you provide explicitly, you can react to events that happen within talk by starting it with a callback module as the sole argument. This might be helpful for debugging.
The module has to implement the `talk_event_handler` behaviour.

call                                          |meaning
----------------------------------------------|---
`handle_event(init)`|will be called apon init
`handle_event({wait_for_ack, Packet})`|when talk was told to wait for acknowledgement
`handle_event({ack, Packet})`|when a packet was acknowledged by the other side
`handle_event({ignore, LocalSeq, Ack})`|when we receive an acknowledgement for a packet we did not send



## Headers

This is the structure of the headers that are used by talk.

*IMPORTANT* The byte order is network order/big endian.


```

+---------+------------+-------+------------------+-------+--------------+---------+--------------+--------+
|  8 Bit  |   64Bit    | 32Bit |       32Bit      | 32Bit |    32Bit     |  8Bit   |     8Bit     | Rest   |
+---------+------------|-------|------------------|-------|--------------|---------|--------------|--------+
|Signature| ResourceId | SeqNr | Equivalent SeqNr |  Ack  | Ack Bitfield | Command |  Compression |Payload |
+---------+------------+-------+------------------+-------+--------------+---------+--------------+--------+

```


Field|Meaning
-----|-------
Signature| A static value to identify the protocol, currently 96
ResourceId       | An integer identifying the resource this packet is addressed to for dispatch
SeqNr            | The monotonically increasing sequence number of this packet
Equivalent SeqNr | If have this number set to the sam, non-zero value, it means they are equivalent
Ack              | The sequence number of the last seen message
Ack Bitfield     | History of the last 32 packet we saw before Ack. If Ack is `113` and the Bitfield is `11000000 11111111 11111111 11111111` we saw 113, 112, 111 and 104 to 81
Command          | A user defined command
Compression      | The type of compression
Payload          | The actual content of the message
