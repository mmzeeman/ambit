-module(hexveil_test).

-include_lib("eunit/include/eunit.hrl").

encode_decode_round_trip_test() ->
    Points = [
        {52.3616, 4.8784},    %% Vondelpark
        {-33.8688, 151.2093}, %% Sydney
        {40.7128, -74.0060},  %% New York
        {0.0, 0.0}            %% Null Island
    ],
    lists:foreach(
      fun({Lat, Lon}) ->
              Digits = hexveil:encode(Lat, Lon),
              ?assertEqual(40, byte_size(Digits)),
              {Lat2, Lon2} = hexveil:decode(Digits),
              ?assert(abs(Lat - Lat2) < 0.0001),
              ?assert(abs(Lon - Lon2) < 0.0001)
      end,
      Points).

display_parse_round_trip_test() ->
    Digits = hexveil:encode(52.3616, 4.8784),
    Binary = hexveil:display(Digits),
    ?assertEqual(14, byte_size(Binary)),
    %% Parsing now returns EXACT digits because of the sentinel bit
    ?assertEqual(Digits, hexveil:parse(Binary)).

prefix_property_test() ->
    Digits = hexveil:encode(52.3616, 4.8784),
    P1 = hexveil:display(hexveil:coarsen(Digits, 24)), %% Level 24: (24+1)/3 = 9 chars
    P2 = hexveil:display(hexveil:coarsen(Digits, 23)), %% Level 23: (23+1)/3 = 8 chars
    P3 = hexveil:display(hexveil:coarsen(Digits, 22)), %% Level 22: (22+1)/3 = 8 chars
    P4 = hexveil:display(hexveil:coarsen(Digits, 21)), %% Level 21: (21+1)/3 = 8 chars
    P5 = hexveil:display(hexveil:coarsen(Digits, 20)), %% Level 22: (20+1)/3 = 7 chars
    ?assertEqual(9, byte_size(P1)),
    ?assertEqual(8, byte_size(P2)),
    ?assertEqual(8, byte_size(P3)),
    ?assertEqual(8, byte_size(P4)),
    ?assertEqual(7, byte_size(P5)),
    %% P2 and P3 share a prefix, but their last char (containing sentinel) differs
    ?assertEqual(binary:part(P3, 0, 7), binary:part(P2, 0, 7)).

hierarchy_containment_test() ->
    %% Null Island is perfectly linear in our projection (CosLat = 1.0)
    ParentDigits = binary:part(hexveil:encode(0.0, 0.0), 0, 30),
    {PLat, PLon} = hexveil:decode(ParentDigits),

    %% Children of this parent
    C0 = <<ParentDigits/binary, 0>>,
    C1 = <<ParentDigits/binary, 1>>,
    C2 = <<ParentDigits/binary, 2>>,

    {Lat0, Lon0} = hexveil:decode(C0),
    {Lat1, Lon1} = hexveil:decode(C1),
    {Lat2, Lon2} = hexveil:decode(C2),

    %% The average of children should be the parent
    ?assert(abs(PLat - (Lat0+Lat1+Lat2)/3) < 1.0e-8),
    ?assert(abs(PLon - (Lon0+Lon1+Lon2)/3) < 1.0e-8).

