-module(hexveil_test).

-include_lib("eunit/include/eunit.hrl").

encode_decode_round_trip_test() ->
    Points = [
        {90.0, 0.0},          %% North Pole
        {-90.0, 0.0},         %% South Pole
 %       {0.0, 180.0},         %% Equator / IDL
 %       {0.0, -180.0},        %% Equator / IDL
        {85.0, 179.9},        %% High latitude
        {-85.0, -179.9},      %% High latitude
       {10.0, 10.0},         %% Some point
        {48.0, 16.0},
         {0.5, 0.5},           %% Within 141km
        {-0.2, 0.1},          %% Within 141km
        {0.0, 0.0}            %% Null Island
    ],
    lists:foreach(
      fun({Lat, Lon}) ->
              FullDigits = hexveil:encode(Lat, Lon),
              ?assertEqual(32, byte_size(FullDigits)),

              lists:foreach(
                fun(L) ->
                        Digits = hexveil:coarsen(FullDigits, L),
                        {Lat2, Lon2} = hexveil:decode(Digits),
                        
                        Dist = distance_m(Lat, Lon, Lat2, Lon2),
                        
                        %% Expected circumradius at level L
                        %% R = 1.732 * sqrt(3)^(32-L)
                        ExpectedR = 1.7320508 * math:pow(math:sqrt(3), 32 - L) * 1.05,
                        
                        %% Margin for projection distortion (especially at poles)
                        Tolerance = if abs(Lat) > 89.9 -> ExpectedR * 3.0;
                                       abs(Lat) > 80.0 -> ExpectedR * 10.0;
                                       true -> ExpectedR * 1.5 
                                    end,

                        io:format(user, "Level ~p | Lat: ~5.1f, Lon: ~6.1f -> Dist: ~10.2f m (ExpectedR: ~10.2f m)~n", 
                                  [L, Lat, Lon, Dist, ExpectedR]),
                        
                        ?assert(Dist < Tolerance)
                end,
                [32, 25, 24, 23, 15])
      end,
      Points).

%% Haversine distance in meters
distance_m(Lat1, Lon1, Lat2, Lon2) ->
    R = 6371000, %% Earth radius
    Phi1 = Lat1 * math:pi() / 180,
    Phi2 = Lat2 * math:pi() / 180,
    DPhi = (Lat2 - Lat1) * math:pi() / 180,
    DLon = (Lon2 - Lon1) * math:pi() / 180,
    A = math:sin(DPhi/2) * math:sin(DPhi/2) +
        math:cos(Phi1) * math:cos(Phi2) *
        math:sin(DLon/2) * math:sin(DLon/2),
    C = 2 * math:atan2(math:sqrt(A), math:sqrt(1-A)),
    R * C.

display_parse_round_trip_test() ->
    Digits = hexveil:encode(52.3616, 4.8784),
    Binary = hexveil:display(Digits),
    ?assertEqual(11, byte_size(Binary)),
    %% Parsing now returns EXACT digits because of the sentinel bit
    ?assertEqual(Digits, hexveil:parse(Binary)).

prefix_property_test() ->
    Digits = hexveil:encode(52.3616, 4.8784),
    P1 = hexveil:display(hexveil:coarsen(Digits, 24)), %% Level 24: (24+1)/3 = 9 chars
    P2 = hexveil:display(hexveil:coarsen(Digits, 23)), %% Level 23: (23+1)/3 = 8 chars
    P3 = hexveil:display(hexveil:coarsen(Digits, 22)), %% Level 22: (22+1)/3 = 8 chars
    P4 = hexveil:display(hexveil:coarsen(Digits, 21)), %% Level 21: (21+1)/3 = 8 chars
    P5 = hexveil:display(hexveil:coarsen(Digits, 20)), %% Level 20: (20+1)/3 = 7 chars
    ?assertEqual(9, byte_size(P1)),
    ?assertEqual(8, byte_size(P2)),
    ?assertEqual(8, byte_size(P3)),
    ?assertEqual(8, byte_size(P4)),
    ?assertEqual(7, byte_size(P5)),
    %% P2 and P3 share a prefix, but their last char (containing sentinel) differs
    ?assertEqual(binary:part(P3, 0, 7), binary:part(P2, 0, 7)).

hierarchy_containment_test() ->
    %% Null Island is perfectly linear in our projection (CosLat = 1.0)
    ParentDigits = binary:part(hexveil:encode(0.0, 0.0), 0, 20),
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
