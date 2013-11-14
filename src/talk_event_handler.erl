-module(talk_event_handler).

-export([behaviour_info/1]).

behaviour_info(callbacks) ->
    [{handle_event, 1}];
behaviour_info(_) ->
    undefined.

