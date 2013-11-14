-module(talk_protocol).

-include("talk_protocol.hrl").

-compile([export_all]).

assemble_packet(
    Header = << _:208/bitstring, Compression:8/integer >>,
    Payload) ->

    PayloadCompressed = compress(Compression, Payload),
    << Header/binary, PayloadCompressed/binary >>.

decode_seq_no(<<
        _ProtoSig/integer,
        _UserId:64/integer,
        SeqNo:32/integer,
        _/binary
    >>) ->
    SeqNo.

decode_command(<<
        _ProtoSig/integer,
        _UserId:64/integer,
        _SeqNo:32/integer,
        _EqSeqNo:32/integer,
        _Ack:32/integer,
        _Bitfield:32/bitstring,
        Command:8/integer,
        _/binary
    >>) ->

    Command.

decode_metadata(<<
        _ProtoSig/integer,
        _UserId:64/integer,
        RemoteSeqNo:32/integer,
        EqSeqNo:32/integer,
        Ack:32/integer,
        Bitfield:32/bitstring,
        _/binary >>) ->

    {{RemoteSeqNo, EqSeqNo}, {Ack, Bitfield}}.

decode_command_data(<<
        _ProtoSig/integer,
        UserId:64/integer,
        _RemoteSeqNo:32/integer,
        _EqSeqNo:32/integer,
        _Ack:32/integer,
        _Bitfield:32/bitstring,
        Command:8/integer,
        Compression:8/integer,
        Payload/binary >>) ->
    {UserId, Command, decompress(Compression, Payload)}.

set_sequence_id_and_ack(Seq, Ack, Bitfield, << Header:216/bitstring, Payload/bitstring >>) ->
    {UserId, {_, EqSeq}, _, Command, Compression} = decode_header(Header),
    NewHeader = encode_header(UserId, {Seq, EqSeq}, {Ack, Bitfield}, Command, Compression),
    << NewHeader/bitstring, Payload/bitstring >>.


encode_header(UserId, {SeqNo, EqSeqNo}, {Ack, Bitfield}, Command, Compression) ->
    <<
        ?ProtoSig/integer,
        UserId:64/integer,
        SeqNo:32/integer,
        EqSeqNo:32/integer,
        Ack:32/integer,
        Bitfield:32/bitstring,
        Command:8/integer,
        Compression:8/integer
    >>.

decode_header(
    <<
        _ProtoSig/integer,
        UserId:64/integer,
        SeqNo:32/integer,
        EqSeqNo:32/integer,
        Ack:32/integer,
        Bitfield:32/bitstring,
        Command:8/integer,
        Compression:8/integer,
        _/binary
    >>) ->

    {UserId, {SeqNo, EqSeqNo}, {Ack, Bitfield}, Command, Compression}.

compress(?NoCompression,  Data) -> Data;
compress(?ZipCompression, Data) -> zlib:compress(Data).

decompress(_,               <<>>) -> <<>>;
decompress(?NoCompression,  Data) -> Data;
decompress(?ZipCompression, Data) -> zlib:uncompress(Data).
