-module(geohex_test).

-include_lib("eunit/include/eunit.hrl").

encode_decode_round_trip_test() ->
    Points = [
        {52.3026, 4.6889},  %% Amsterdam
        {-33.8688, 151.2093}, %% Sydney
        {40.7128, -74.0060}, %% New York
        {-23.5505, -46.6333}, %% São Paulo
        {0.0, 0.0}            %% Null Island
    ],
    lists:foreach(
      fun({Lat, Lon}) ->
          Code = geohex:encode(Lat, Lon),
          {Lat2, Lon2} = geohex:decode(Code),
          ?assert(is_integer(element(1, Code))),
          ?assert(is_integer(element(2, Code))),
          ?assert(abs(Lat - Lat2) < 0.0001),
          ?assert(abs(Lon - Lon2) < 0.0001)
      end,
      Points).

display_parse_round_trip_test() ->
    Codes = [
        geohex:encode(52.3026, 4.6889),
        geohex:encode(0.0, 0.0)
    ],
    lists:foreach(
      fun(Code) ->
          Full = geohex:display(Code),
          ?assertEqual(12, byte_size(Full)),
          ?assertEqual(Code, geohex:parse(Full)),
          ?assertEqual(9, byte_size(geohex:display(Code, 18))),
          ?assertEqual(9, byte_size(geohex:display(Code, 17))),
          ?assertEqual(8, byte_size(geohex:display(Code, 16))),
          ?assertEqual(1, byte_size(geohex:display(Code, 1)))
      end,
      Codes).

display_prefix_property_test() ->
    Code = geohex:encode(52.3026, 4.6889),
    %% In Base-16 (Hex), prefixes only hold for EVEN levels.
    S16 = geohex:display(Code, 16),
    S18 = geohex:display(Code, 18),
    S24 = geohex:display(Code, 24),

    ?assert(binary_prefix(S16, S18)),
    ?assert(binary_prefix(S18, S24)).

coarsen_consistency_test() ->
    Code = geohex:encode(52.3026, 4.6889),
    ?assertEqual(Code, geohex:coarsen(Code, 24)),
    %% Canonical test: parse(display(Code, L)) should be the same as coarsen(Code, L)
    %% because they both represent the same cell ID in the hierarchy.
    ?assertEqual(geohex:coarsen(Code, 18), geohex:coarsen(geohex:parse(geohex:display(Code, 18)), 18)),
    ?assertEqual(geohex:coarsen(Code, 17), geohex:coarsen(geohex:parse(geohex:display(Code, 17)), 17)),
    ?assertEqual(geohex:coarsen(Code, 16), geohex:coarsen(geohex:parse(geohex:display(Code, 16)), 16)).

are_nearby_test() ->
    Code = geohex:encode(52.3026, 4.6889),
    SameCell = geohex:encode(52.302601, 4.688901),
    DifferentButNearby = geohex:encode(52.3035, 4.6895),

    ?assert(geohex:are_nearby(Code, SameCell, 24)),
    ?assert(geohex:are_nearby(Code, SameCell, 18)),
    ?assertNot(geohex:are_nearby(Code, DifferentButNearby, 24)),
    ?assert(geohex:are_nearby(Code, DifferentButNearby, 16)).

neighbors_test() ->
    Code = geohex:encode(52.3026, 4.6889),
    Neighbors = geohex:neighbors(Code),
    ?assertEqual(6, length(Neighbors)),
    ?assertEqual(
        lists:sort([
            {element(1, Code) + 1, element(2, Code)},
            {element(1, Code), element(2, Code) + 1},
            {element(1, Code) - 1, element(2, Code) + 1},
            {element(1, Code) - 1, element(2, Code)},
            {element(1, Code), element(2, Code) - 1},
            {element(1, Code) + 1, element(2, Code) - 1}
        ]),
        lists:sort(Neighbors)
    ).

cell_bounds_sanity_test() ->
    Code = geohex:encode(52.3026, 4.6889),
    {MinLat, MinLon, MaxLat, MaxLon} = geohex:cell_bounds(Code),
    {CLat, CLon} = geohex:decode(Code),
    ?assert(MinLat < CLat),
    ?assert(MinLon < CLon),
    ?assert(MaxLat > CLat),
    ?assert(MaxLon > CLon),
    ?assert(MaxLat > MinLat),
    ?assert(MaxLon > MinLon).

binary_prefix(Prefix, Binary) ->
    Len = byte_size(Prefix),
    byte_size(Binary) >= Len andalso binary:part(Binary, 0, Len) =:= Prefix.
