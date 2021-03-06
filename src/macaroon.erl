-module(macaroon).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-load(init/0).
-export([init/0]).
-export([create/3]).
-export([add_first_party_caveat/2]).
-export([add_third_party_caveat/4]).
-export([prepare_for_request/2]).
-export([serialize/1]).
-export([deserialize/1]).
-export([deserialize_multiple/1]).
-export([inspect/1]).
-export([verify/3]).
-export([verify/4]).
-export([verify_with_log/4]).
-export([verify_signature/2]).
-export([create_verifier/0]).
-export([add_exact_satisfy/2]).
-export([add_general_satisfy/3]).
-export([bind_to_signature/2]).
-export([
	get_signature/1,
	get_identifier/1,
	get_location/1,
    get_caveats/1,
    extract_info/1,
    extract_info/2
	]).


-record(macaroon, {
		location = undefined,
		identifier = undefined,
		signature = undefined,
		caveats = []
		}).

-record(caveat, {
		cid = undefined,
		vid = undefined,
		cl = undefined
		}).

-record(verifier, {
		exact = [],
		general = []
		}).

-define(KEY_BYTE_SIZE,32).
-define(MAX_STRLEN,32768).
-define(MAX_CAVEATS,65536).
-define(SUGGESTED_SECRET_LENGTH,32).
-define(SECRET_NONCE_BYTES,24).
-define(SECRET_TEXT_ZERO_BYTES,32).
-define(SECRET_BOX_ZERO_BYTES,16).


-spec init() -> ok.
init() ->
	Nif = filename:join([code:priv_dir(?MODULE), "macaroon"]), 
	ok = erlang:load_nif(Nif,0),
	ok.

-spec create(Location::binary(), Id::binary(), Key::binary()) -> #macaroon{}.
create(Location, Id, VarKey) ->
	Key = generate_derived_key(VarKey),
	create_raw(Location,Id,Key).

-spec add_first_party_caveat(Predicate::binary(),#macaroon{}) -> #macaroon{}.
add_first_party_caveat(Predicate, #macaroon{caveats=Cavs, signature=Sig}=Mac) ->
			true = ((length(Cavs) + 1) < ?MAX_CAVEATS),
            NewSig = hash1(Sig,Predicate),
            NewCavs = Cavs ++ [#caveat{cid=Predicate}],
			Mac#macaroon{caveats=NewCavs,signature=NewSig}.



-spec add_third_party_caveat(Location::binary(), Id::binary(), VarKey::binary(), #macaroon{}) -> #macaroon{}.
add_third_party_caveat(Location,Id,VarKey,Macaroon) ->
	% The Id needs to contain the VarKey in an encrypted way as well
	% as informations on what should be satisfied
	Key = generate_derived_key(VarKey),
	add_third_party_caveat_raw(Location,Id,Key,Macaroon).

-spec get_signature(#macaroon{}) -> binary().
get_signature(#macaroon{signature=Sig}) ->
	macaroon_utils:bin_to_hex(Sig).

-spec get_location(#macaroon{}) -> binary().
get_location(#macaroon{location=Loc}) ->
	Loc.

-spec get_identifier(#macaroon{}) -> binary().
get_identifier(#macaroon{identifier=Id}) ->
	Id.

-spec get_caveats(#macaroon{}) -> [{term(), term(), term()}].
get_caveats(#macaroon{caveats=Caveats}) ->
    caveats_to_list(Caveats,[]).

-spec extract_info(#macaroon{}) -> map().
extract_info(Macaroon) ->
    extract_info(Macaroon,undefined).

-spec extract_info(#macaroon{}, Key ::binary() | undefined) -> map().
extract_info(Macaroon,VarKey) ->
    #macaroon{identifier=Id,
              signature=Sig,
              location=Loc,
              caveats=Cav} = Macaroon,
	Key = generate_derived_key(VarKey),
	Sig1 = hmac(Key,Id),
    MacMap = #{identifier => Id,
               in_signature => Sig,
               signature => Sig1,
               location => Loc,
               caveats => []
              },
    extract_caveat_info(Cav,Key,MacMap).




-spec prepare_for_request(TopMacaroon :: #macaroon{}, Discharge :: #macaroon{}) -> #macaroon{} | {error,badarg}.
prepare_for_request( TM, #macaroon{signature=Sig,identifier=Id} = DischargeM ) ->
	case contains_cid(TM,Id) of 
		true -> NewSig = bind_to_top_macaroon(TM,Sig),
			DischargeM#macaroon{signature=NewSig};
		false ->
			{error,badarg}
	end.
		

-spec serialize(Macaroon :: #macaroon{} ) -> Base64UrlEncoded :: binary().
serialize(#macaroon{identifier=Id, location=Loc, signature=Sig, caveats=Cav}) ->
    CavKVList = get_caveat_kvs(Cav,[]),
    KVList = [{location,Loc},{identifier,Id}] ++ CavKVList ++ [{signature, Sig}],
    macaroon_utils:serialize_kv_list(KVList).

-spec deserialize(Base64UrlEncoded :: binary()) -> #macaroon{}.
deserialize(Data) ->
    [RawMacaroon] = binary:split(Data,[<<" ">>],[global,trim_all]),
    {ok,KVList} = macaroon_utils:parse_kv(RawMacaroon,true),
	build_macaroon(KVList).

-spec deserialize_multiple(Base64UrlEncoded :: binary()) -> [#macaroon{}].
deserialize_multiple(Data) ->
    RawMacaroons = binary:split(Data,[<<",">>],[global,trim_all]),
    BuildMacaroon = fun(RawMac,List) ->
                            M = deserialize(RawMac),
                            [M | List]
                    end,
    lists:reverse(lists:foldl(BuildMacaroon,[],RawMacaroons)).

-spec inspect(Macaroon :: #macaroon{}) -> AsciiEncoded :: binary().
inspect(#macaroon{identifier=Id,location=Loc,signature=Sig,caveats=Cav}) ->
    CavKVList = get_caveat_kvs(Cav,[]),
    KVList = [{location,Loc},{identifier,Id}] ++ CavKVList ++ [{signature, Sig}],
    macaroon_utils:inspect_kv_list(KVList).


-spec bind_to_signature(Macaroon :: #macaroon{}, Base64EncodedSignature :: binary()) -> #macaroon{}.
bind_to_signature(#macaroon{signature=Sig}=M,MainSigBase64) ->
    MainSig = base64url:decode(MainSigBase64),
    NewSig = bind_signature(MainSig,Sig),
    M#macaroon{signature=NewSig}.

-spec create_verifier() -> #verifier{}.
create_verifier() -> 
	#verifier{}.

-spec add_exact_satisfy(Satisfy :: binary(), Verifier::#verifier{}) -> NewVerifier::#verifier{}.
add_exact_satisfy(Satisfy,#verifier{exact=Exact}=V) ->
	V#verifier{exact=[Satisfy|Exact]}.

-spec add_general_satisfy(Name :: binary(), Satisfy :: fun(), Verifier::#verifier{}) -> NewVerifier::#verifier{}.
add_general_satisfy(Name,Satisfy,#verifier{general=General}=V) ->
	V#verifier{general=[{Name,Satisfy}|General]}.

-spec verify(#macaroon{}, Key::binary(), #verifier{}) -> true | false.
verify(Macaroon, VarKey, Verifier) ->
	verify(Macaroon,VarKey,[],Verifier).

-spec verify(#macaroon{}, Key::binary(), [#macaroon{}], #verifier{}) -> true | false.
verify(Macaroon, VarKey, Discharges, Verifier) ->
	Key = generate_derived_key(VarKey),
	verify_raw(Macaroon,Key,Discharges,Verifier,undefined).
	
-spec verify_with_log(#macaroon{}, Key::binary(), [#macaroon{}], #verifier{}) -> true | false.
verify_with_log(Macaroon, VarKey, Discharges, Verifier) ->
    {ok,Pid} = macaroon_log:start_link(),
	Key = generate_derived_key(VarKey),
	Result = verify_raw(Macaroon,Key,Discharges,Verifier,Pid),
    {ok, Log} = macaroon_log:get_log(Pid),
    ok = macaroon_log:stop(Pid),
    {Result,Log}.

%%%%% INTERNAL %%%%%%%%%
-spec create_raw(Location::binary(), Id::binary(), Key::binary()) -> #macaroon{}.
create_raw(Location, Id, Key) ->
	true = (byte_size(Location) < ?MAX_STRLEN),
	true = (byte_size(Id) < ?MAX_STRLEN),
	?KEY_BYTE_SIZE = byte_size(Key),
	Sig = hmac(Key,Id),
	#macaroon{location=Location, identifier=Id, signature=Sig}.

-spec add_third_party_caveat_raw(Location::binary(), Id::binary(), Key::binary(), #macaroon{}) -> #macaroon{}.
add_third_party_caveat_raw(Location,Id,Key,#macaroon{caveats=Cavs, signature=Sig}=Mac) ->
	true = (byte_size(Location) < ?MAX_STRLEN),
	true = (byte_size(Id) < ?MAX_STRLEN),
	?SUGGESTED_SECRET_LENGTH = byte_size(Key),
	true = ((length(Cavs) +1 ) < ?MAX_CAVEATS),
	Nonce = crypto:rand_bytes(?SECRET_NONCE_BYTES),
	ZeroBits = 8 * ?SECRET_TEXT_ZERO_BYTES,
	EncKey = secretbox(<<0:ZeroBits,Key/binary>>,Nonce,Sig),	
	Vid = <<Nonce/binary,EncKey/binary>>,
    NewSig = hash2(Sig,Vid,Id), 
	NewCavs = Cavs ++ [#caveat{cid=Id,vid=Vid,cl=Location}],
	Mac#macaroon{signature=NewSig,caveats=NewCavs}.


get_caveat_kvs([],KVList) ->
	lists:reverse(KVList);
get_caveat_kvs([#caveat{cid=Cid,vid=Vid,cl=Cl}|Tail],KVList) ->
	get_caveat_kvs(Tail,[{cl,Cl},{vid,Vid},{cid,Cid}|KVList]).

build_macaroon(KVList) ->
	build_macaroon(KVList,#macaroon{}).

build_macaroon([{location,Loc}|Tail],#macaroon{location=undefined}=M) ->
	build_macaroon(Tail,M#macaroon{location=Loc});
build_macaroon([{identifier,Id}|Tail],#macaroon{identifier=undefined}=M) ->
	build_macaroon(Tail,M#macaroon{identifier=Id});
build_macaroon([{cid,CaveatId},Next|Tail],#macaroon{signature=undefined,caveats=Cavs}=M) ->
    C = #caveat{cid=CaveatId},
    M2 = M#macaroon{caveats=[C|Cavs]},
    build_macaroon([Next|Tail],M2);
build_macaroon([{vid,CaveatVId},Next|Tail],#macaroon{signature=undefined,caveats=Cavs}=M) ->
    [C|CavTail] = Cavs,
    M2 = M#macaroon{caveats=[C#caveat{vid=CaveatVId}|CavTail]},
    build_macaroon([Next|Tail],M2);
build_macaroon([{cl,CaveatLoc},Next|Tail],#macaroon{signature=undefined,caveats=Cavs}=M) ->
    [C|CavTail] = Cavs,
    M2 = M#macaroon{caveats=[C#caveat{cl=CaveatLoc}|CavTail]},
    build_macaroon([Next|Tail],M2);
build_macaroon([{signature,Sig}],#macaroon{signature=undefined,caveats=Cav}=M) ->
	M#macaroon{signature=Sig,caveats=lists:reverse(Cav)}.

caveats_to_list([],List) ->
    lists:reverse(List);
caveats_to_list([Cav|T],List) ->
    caveats_to_list(T,[caveat_to_map(Cav)|List]).

caveat_to_map(#caveat{cid=Cid,vid=Vid,cl=Cl}) ->
	CidMap = case Cid of
		Cid -> #{cid => Cid}
	end,
	VidMap = case Vid of 
		undefined -> #{vid => <<"">>};
		Vid -> #{ vid => Vid}
	end,
	ClMap = case Cl of
		undefined -> #{cl => <<"">>};
		Cl -> #{ cl => Cl}
	end,
    maps:merge(CidMap,maps:merge(VidMap,ClMap)).


secretbox(_DataToCrypt, _Nonce, _Key) ->
	erlang:error(nif_not_loaded).

secretbox_open(_CipherText, _Nonce, _Key) ->
	erlang:error(nif_not_loaded).

verify_raw(Macaroon,Key,Discharges,Verifier,LogPid) ->
	?SUGGESTED_SECRET_LENGTH = byte_size(Key),
	try
        verify_macaroon(Macaroon,Key,create_discharge_list(Discharges,[]),undefined,Verifier,LogPid) of
		{true,_} -> true;
		_ -> false
	catch 
		false -> false
	end.


extract_caveat_info([],Key,MacMap) ->
    #{signature := Sig,
      in_signature := OrgSig,
      caveats := Caveats
     } = MacMap,
    SigValid = (OrgSig =:= Sig),
    NewInfo = #{caveats => clear_vid_keys_if_not_valid(Caveats,SigValid),
                sig_valid => SigValid,
                key => Key
               }, 
    maps:merge(MacMap,NewInfo);
extract_caveat_info([#caveat{cid=Cid,vid=undefined} | Tail],Key,MacMap) ->
    #{signature := Sig,
      caveats := Caveats
     } = MacMap,
	NewSig = hash1(Sig,Cid),	
    NewInfo = #{caveats => [#{cid=>Cid, vid=>undefined,cl=>undefined}|Caveats],
                signature => NewSig
               }, 
    extract_caveat_info(Tail,Key,maps:merge(MacMap,NewInfo));
extract_caveat_info([#caveat{cid=Cid,vid=Vid,cl=Cl} | Tail],Key,MacMap) ->
    #{signature := Sig,
      caveats := Caveats
     } = MacMap,
    VidKey = get_discharge_key(Vid,Sig),
    NewSig = hash2(Sig,Vid,Cid), 
    NewInfo = #{caveats => [#{cid=>Cid, vid=>Vid, cl=>Cl, vid_key=>VidKey}|Caveats],
                signature => NewSig
               }, 
    extract_caveat_info(Tail,Key,maps:merge(MacMap,NewInfo)).

clear_vid_keys_if_not_valid(Caveats,true) ->
    lists:reverse(Caveats);
clear_vid_keys_if_not_valid(Caveats,false) ->
    clear_vid_keys(Caveats,[]).

clear_vid_keys([],CaveatList) ->
    CaveatList;
clear_vid_keys([#{vid := undefined } = Caveat|T],List) ->
    clear_vid_keys(T,[Caveat | List]);
clear_vid_keys([Caveat|T],List) ->
    CleanCaveat = maps:put(vid_key,undefined,Caveat),
    clear_vid_keys(T,[CleanCaveat |List]).



verify_signature(Macaroon,Key) ->
    #{sig_valid := ValidSig} = extract_info(Macaroon,Key),
    ValidSig.


verify_macaroon(#macaroon{identifier=Id,signature=ExpSig,caveats=Cav}=M,Key,Discharges,TM,Verifier,LogPid) ->
    macaroon_log:begin_macaroon(Id,LogPid),
    Sig1 = hmac(Key,Id),
    TopMacaroon = case TM of 
                      undefined -> 
                          macaroon_log:add_text("setting as TopMacaroon",[],true,LogPid),
                          M;
                      TM -> TM 
                  end,
    {Sig2,NewDischarges} =
    verify_caveats(Cav,Sig1,Discharges,TopMacaroon,Verifier,LogPid),
    CalcSig = case TM of 
                  undefined -> 
                      % is the main macaroon, nothing else to do here
                      Sig2;
                  TM ->
                      macaroon_log:add_text("BindToTopMacaroon",[],true,LogPid),
                      bind_to_top_macaroon(TM,Sig2)
              end,
    ValidSig = (ExpSig =:= CalcSig),
    macaroon_log:add_text("validating signature ~s",[base64url:encode(CalcSig)],ValidSig,LogPid),
    macaroon_log:end_macaroon(LogPid),
    {ValidSig,NewDischarges}.
		

verify_caveats([],Signature,Discharges,_TopMacaroon,_Verifier,_LogPid) ->
	{Signature,Discharges};
verify_caveats([#caveat{cid=Cid,vid=undefined}|Tail],Signature,Discharges,TopMacaroon,Verifier,LogPid) ->
	% first party caveat
	ok = verify_predicate(Cid,Verifier,LogPid),
	NewSig = hash1(Signature,Cid),	
	verify_caveats(Tail,NewSig,Discharges,TopMacaroon,Verifier,LogPid);
verify_caveats([#caveat{cid=Cid,vid=Vid}|Tail],Signature,Discharges,TopMacaroon,Verifier,LogPid) ->
	% third party caveat
	case lists:keyfind(Cid,1,Discharges) of 
		{Cid,Discharge} ->
            Key = get_discharge_key(Vid,Signature),
			Discharges1 = lists:keydelete(Cid,1,Discharges),
			case
                verify_macaroon(Discharge,Key,Discharges1,TopMacaroon,Verifier,LogPid) of
				{true, Discharges2} ->
					NewSig = hash2(Signature,Vid,Cid), 
					verify_caveats(Tail,NewSig,Discharges2,TopMacaroon,Verifier,LogPid);
				_ -> 
                    macaroon_log:add_text("discharge macaroon ~p missing",[Cid],false,LogPid), 
                    throw(false)
			end;
		_ ->
			throw(false)
	end.




get_discharge_key(_Vid,undefined) ->
    undefined;
get_discharge_key(Vid,Signature) ->
    <<Nonce:?SECRET_NONCE_BYTES/binary,EncKey/binary>> = Vid,
    ZeroBits = ?SECRET_BOX_ZERO_BYTES *8,
    CipherText = <<0:ZeroBits,EncKey/binary>>,
    secretbox_open(CipherText,Nonce,Signature).


verify_predicate(Pred,#verifier{exact=Exact,general=General},LogPid) ->
	case lists:member(Pred,Exact) of 
		true -> 
            macaroon_log:add_text("~p verified (exact)",[Pred],true,LogPid),
            ok;
		false -> 
			VFun = fun({Name,GFun},Bool) ->
					case GFun(Pred) of
						true -> 
                            macaroon_log:add_text("~p verified (by function ~p)",[Pred,Name],true,LogPid),
                            true;
						_ -> Bool
					end
			end,
			case lists:foldl(VFun,false,General) of
				true -> ok;
				_ -> 
                    macaroon_log:add_text("~p can't be verified",[Pred],false,LogPid),
                    throw(false)
			end
	end.

create_discharge_list([],Result) ->
	Result;
create_discharge_list([#macaroon{identifier=Id} = M|Tail],Result) ->
	create_discharge_list(Tail,[{Id,M}|Result]).


bind_to_top_macaroon(#macaroon{signature=MainSig},DcSig) ->
    bind_signature(MainSig,DcSig).

bind_signature(TopMacaroonSig,DischargeMacaroonSig) ->
	ZeroBits = 8 * ?SUGGESTED_SECRET_LENGTH,
	hash2(<<0:ZeroBits>>,TopMacaroonSig,DischargeMacaroonSig).




contains_cid(#macaroon{caveats=Cavs},Id) when is_binary(Id) ->
	contains_cid(Cavs,Id);
contains_cid([],_) ->
	false;
contains_cid([#caveat{cid=Cid}|Tail],Id) ->
	case Cid == Id of
		true -> true;
		false -> 
			contains_cid(Tail,Id)
	end.

generate_derived_key(undefined) -> 
    undefined;
generate_derived_key(Key) -> 
	hmac(<<"macaroons-key-generator">>,Key).


hash1(undefined, _Data) ->
    undefined;
hash1(Key, Data) ->
	hmac(Key,Data).

hash2(undefined, _Data1, _Data2) ->
    undefined;
hash2(Key, Data1, Data2) ->
	Hmac1 = hmac(Key,Data1),
	Hmac2 = hmac(Key,Data2),
	hmac(Key,<<Hmac1/binary,Hmac2/binary>>).


-spec hmac(Key::binary(), Data::binary()) -> Mac::binary().
hmac(VarKey,Data) ->
	Key = case byte_size(VarKey) >= ?KEY_BYTE_SIZE of 
		true ->
			% trucate if too long
			<<NK:?KEY_BYTE_SIZE/binary,_/binary>> = VarKey,
			NK;
		false ->
			% fill with trailing zeros, if too short
			ZeroBits = (?KEY_BYTE_SIZE - byte_size(VarKey)) * 8,
			Zeros = <<0:ZeroBits>>,
			<<VarKey/binary,Zeros/binary>>
	end,
	crypto:hmac(sha256,Key,Data,?KEY_BYTE_SIZE).




-ifdef(TEST).
nif_load_test() ->
	ok = init().

basic_macaroon_signature_test() ->
	Key1 = <<"this is our super secret key; only we should know it">>,
	Key2 = <<"this is our super secret key; only we should know it ...">>,
	Public = <<"we used our secret key">>,	
	Location = <<"http://mybank/">>,
	Macaroon = create(Location, Public, Key1),
	<<"e3d9e02908526c4c0039ae15114115d97fdd68bf2ba379b342aaf0f617d0552f">> = get_signature(Macaroon),
    true =  verify_signature(Macaroon,Key1),
    false =  verify_signature(Macaroon,Key2).

simple_inspect_test() ->
	Key = <<"this is our super secret key; only we should know it">>,
	Public = <<"we used our secret key">>,	
	Location = <<"http://mybank/">>,
	M1 = create(Location, Public, Key),
	M2 = add_first_party_caveat(<<"account = 1234">>,M1),
    Expected = <<"location http://mybank/\nidentifier we used our secret key\ncid account = 1234\nsignature 969b21c9326d15be6966727f39379d558bcb621fffff4a7e4b7c67b819ef23e3\n">>,
	Expected = inspect(M2).



first_party_caveat_test() ->
	Key = <<"this is our super secret key; only we should know it">>,
	Public = <<"we used our secret key">>,	
	Location = <<"http://mybank/">>,
	M1 = create(Location, Public, Key),
	M2 = add_first_party_caveat(<<"account = 3735928559">>,M1),
	<<"1efe4763f290dbce0c1d08477367e11f4eee456a64933cf662d79772dbb82128">> = get_signature(M2),
	M3 = add_first_party_caveat(<<"time < 2020-01-01T00:00">>,M2),
	<<"b5f06c8c8ef92f6c82c6ff282cd1f8bd1849301d09a2db634ba182536a611c49">> = get_signature(M3),
	M4 = add_first_party_caveat(<<"email = alice@example.org">>,M3),
	<<"ddf553e46083e55b8d71ab822be3d8fcf21d6bf19c40d617bb9fb438934474b6">> = get_signature(M4),
	ok.

serialize_test() ->
	Key = <<"this is our super secret key; only we should know it">>,
	Public = <<"we used our secret key">>,	
	Location = <<"http://mybank/">>,
	Macaroon = create(Location, Public, Key),
	<<"MDAxY2xvY2F0aW9uIGh0dHA6Ly9teWJhbmsvCjAwMjZpZGVudGlmaWVyIHdlIHVzZWQgb3VyIHNlY3JldCBrZXkKMDAyZnNpZ25hdHVyZSDj2eApCFJsTAA5rhURQRXZf91ovyujebNCqvD2F9BVLwo">> = serialize(Macaroon).


parse_test() ->
	Public = <<"we used our secret key">>,	
	Location = <<"http://mybank/">>,
	Signature = <<"e3d9e02908526c4c0039ae15114115d97fdd68bf2ba379b342aaf0f617d0552f">>,
	M = deserialize(<<"MDAxY2xvY2F0aW9uIGh0dHA6Ly9teWJhbmsvCjAwMjZpZGVudGlmaWVyIHdlIHVzZWQgb3VyIHNlY3JldCBrZXkKMDAyZnNpZ25hdHVyZSDj2eApCFJsTAA5rhURQRXZf91ovyujebNCqvD2F9BVLwo">>),
	Location = get_location(M),
	Signature = get_signature(M),
	Public = get_identifier(M).

parse_with_whitespace_test() ->
	Public = <<"we used our secret key">>,	
	Location = <<"http://mybank/">>,
	Signature = <<"e3d9e02908526c4c0039ae15114115d97fdd68bf2ba379b342aaf0f617d0552f">>,
	M = deserialize(<<"  MDAxY2xvY2F0aW9uIGh0dHA6Ly9teWJhbmsvCjAwMjZpZGVudGlmaWVyIHdlIHVzZWQgb3VyIHNlY3JldCBrZXkKMDAyZnNpZ25hdHVyZSDj2eApCFJsTAA5rhURQRXZf91ovyujebNCqvD2F9BVLwo ">>),
	Location = get_location(M),
	Signature = get_signature(M),
	Public = get_identifier(M).

roundtrip_test() ->
	Key = <<"this is our super secret key; only we should know it">>,
	Public = <<"we used our secret key">>,	
	Location = <<"http://mybank/">>,
	Cav1 = <<"account = 3735928559">>,
	Cav2 = <<"time < 2020-01-01T00:00">>,
	Cav3 = <<"email = alice@example.org">>,
	M1 = create(Location, Public, Key),
	M2 = add_first_party_caveat(Cav1,M1),
	M3 = add_first_party_caveat(Cav2,M2),
	M4 = add_first_party_caveat(Cav3,M3),
	Signature = get_signature(M4),
	M5 = deserialize(serialize(M4)),
	Public = get_identifier(M5),
	Location = get_location(M5),
	[C1,C2,C3] = M5#macaroon.caveats,
	#caveat{cid=Cav1, cl=undefined, vid=undefined} = C1,
	#caveat{cid=Cav2, cl=undefined, vid=undefined} = C2,
	#caveat{cid=Cav3, cl=undefined, vid=undefined} = C3,
	Signature = get_signature(M5).

simple_verify_test() ->
	Key = <<"this is our super secret key; only we should know it">>,
	Public = <<"we used our secret key">>,	
	Location = <<"http://mybank/">>,
	M1 = create(Location, Public, Key),
	M2 = add_first_party_caveat(<<"account = 3735928559">>,M1),
	<<"1efe4763f290dbce0c1d08477367e11f4eee456a64933cf662d79772dbb82128">> = get_signature(M2),
	M3 = add_first_party_caveat(<<"time < 2020-01-01T00:00">>,M2),
	<<"b5f06c8c8ef92f6c82c6ff282cd1f8bd1849301d09a2db634ba182536a611c49">> = get_signature(M3),
	M4 = add_first_party_caveat(<<"email = alice@example.org">>,M3),
	V = create_verifier(),
	V1 = add_exact_satisfy(<<"account = 3735928559">>,V),
	true = verify(M2,Key,V1),
	false = verify(M3,Key,V1),
	TimeSatisfy = fun(Predicate) -> 
			case binary:split(Predicate,[<<" < ">>],[trim]) of
				[<<"time">>,_] -> true;
				_ -> false
			end
	end,
	V2 = add_general_satisfy(<<"time">>,TimeSatisfy,V1),
	true = verify(M3,Key,V2),
	false = verify(M4,Key,V2),
	ValidMails = [<<"alice@example.org">>,<<"jon@doe.org">>,<<"who@minds.eu">>],
	EmailSatisfy = fun(Predicate) ->
			case binary:split(Predicate,[<<" = ">>],[trim]) of
				[<<"email">>,Mail] -> 
					lists:member(Mail,ValidMails);
				_ -> false
			end
	end,
	V3 = add_general_satisfy(<<"Email">>,EmailSatisfy,V2),
	true = verify(M4,Key,V3),

	%change the signature so a different path will fail
	M5 = M4#macaroon{signature= <<"this will never work">>},
	false = verify(M5,Key,V3),
	ok.

third_party_caveat_test() ->
	Key = <<"this is our super secret key; only we should know it">>,
	Public = <<"we used our secret key">>,	
	Location = <<"http://mybank/">>,
	M1 = create(Location, Public, Key),
	M2 = add_first_party_caveat(<<"account = 3735928559">>,M1),
	ThirdPartyKey = <<"this is some random generated key that is really secure.">>,
	ThirdPartyLoc = <<"some great third party">>,
	ThirdPartyId = <<"this should include: Caveat for 3rdPary, The ThridPartyKey and all encrypted">>,
	M3 = add_third_party_caveat(ThirdPartyLoc,ThirdPartyId,ThirdPartyKey,M2),
	M4 = deserialize(serialize(M3)),
	Public = get_identifier(M4),
	Location = get_location(M4),
	ok.

advanced_verify_test() ->
	Key = <<"this is our super secret key; only we should know it">>,
	Public = <<"we used our secret key">>,	
	Location = <<"http://mybank/">>,
	M1 = create(Location, Public, Key),
	M2 = add_first_party_caveat(<<"account = 3735928559">>,M1),
	ThirdPartyKey = <<"this is some random generated key that is really secure.">>,
	ThirdPartyLoc = <<"some great third party">>,
	ThirdPartyId = <<"this should include: Caveat for 3rdPary, The ThridPartyKey and all encrypted">>,
	M3 = add_third_party_caveat(ThirdPartyLoc,ThirdPartyId,ThirdPartyKey,M2),
	M4 = deserialize(serialize(M3)),
	V = create_verifier(),
	V1 = add_exact_satisfy(<<"account = 3735928559">>,V), 
	false = verify(M4,Key,V1),
	D1 = create(<<"some location">>,ThirdPartyId,ThirdPartyKey),
	D2 = add_first_party_caveat(<<"time < now+20">>,D1),
	D3 = prepare_for_request(M3,D2),
	false = verify(M4,Key,[D3],V1),
	TimeSatisfy = fun(Predicate) -> 
			<<"time">> == lists:nth(1, binary:split(Predicate,[<<" < ">>],[trim]))
	end,
	V2 = add_general_satisfy(<<"Time">>,TimeSatisfy,V1),
	true = verify(M4,Key,[D3],V2),
	ok.


advanced_verify_with_log_test() ->
	Key = <<"this is our super secret key; only we should know it">>,
	Public = <<"we used our secret key">>,	
	Location = <<"http://mybank/">>,
	M1 = create(Location, Public, Key),
	M2 = add_first_party_caveat(<<"account = 3735928559">>,M1),
	ThirdPartyKey = <<"this is some random generated key that is really secure.">>,
	ThirdPartyLoc = <<"some great third party">>,
	ThirdPartyId = <<"this should include: Caveat for 3rdPary, The ThridPartyKey and all encrypted">>,
	M3 = add_third_party_caveat(ThirdPartyLoc,ThirdPartyId,ThirdPartyKey,M2),
	M4 = deserialize(serialize(M3)),
	V = create_verifier(),
	V1 = add_exact_satisfy(<<"account = 3735928559">>,V), 
	false = verify(M4,Key,V1),
	D1 = create(<<"some location">>,ThirdPartyId,ThirdPartyKey),
	D2 = add_first_party_caveat(<<"time < now+20">>,D1),
	D3 = prepare_for_request(M3,D2),
	false = verify(M4,Key,[D3],V1),
	TimeSatisfy = fun(Predicate) -> 
			<<"time">> == lists:nth(1, binary:split(Predicate,[<<" < ">>],[trim]))
	end,
	V2 = add_general_satisfy(<<"Time">>,TimeSatisfy,V1),
    {true,Log} = verify_with_log(M4,Key,[D3],V2),
    ct:log("log of the verification: ~p~n",[Log]),
	ok.


hash2_test() ->
	%
	% values taken from the tutorial at rescrv/libmacaroons on github
	%
	%
	ExpSig = macaroon_utils:hex_to_bin("d27db2fd1f22760e4c3dae8137e2d8fc1df6c0741c18aed4b97256bf78d1f55c"),
	OldSig = macaroon_utils:hex_to_bin("1434e674ad84fdfdc9bc1aa00785325c8b6d57341fc7ce200ba4680c80786dda"),
	Vid = base64url:decode(<<"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA027FAuBYhtHwJ58FX6UlVNFtFsGxQHS7uD_w_dedwv4Jjw7UorCREw5rXbRqIKhr">>),
	Id = <<"this was how we remind auth of key/pred">>,	
	ExpSig = hash2(OldSig,Vid,Id).



external_data_verification_test() ->
	% 
	% data generated by using the python binding of rescrv/libmacaroons on github
	%
	%
	% >>> import macaroons
	% >>> secret = 'this is a different super-secret key; never use the same secret twice'
	% >>> public = 'we used our other secret key'
	% >>> location = 'http://mybank/'
	% >>> M = macaroons.create(location, secret, public)
	% >>> M = M.add_first_party_caveat('account = 3735928559')
	% >>> caveat_key = '4; guaranteed random by a fair toss of the dice'
	% >>> predicate = 'user = Alice'
	% >>> identifier = 'this was how we remind auth of key/pred'
	% >>> M = M.add_third_party_caveat('http://auth.mybank/', caveat_key, identifier)
	% >>> D = macaroons.create('http://auth.mybank/', caveat_key, identifier)
	% >>> D = D.add_first_party_caveat('time < 2020-01-01T00:00')
	% >>> DP = M.prepare_for_request(D)
	% >>> M.serialize()
	% 'MDAxY2xvY2F0aW9uIGh0dHA6Ly9teWJhbmsvCjAwMmNpZGVudGlmaWVyIHdlIHVzZWQgb3VyIG90aGVyIHNlY3JldCBrZXkKMDAxZGNpZCBhY2NvdW50ID0gMzczNTkyODU1OQowMDMwY2lkIHRoaXMgd2FzIGhvdyB3ZSByZW1pbmQgYXV0aCBvZiBrZXkvcHJlZAowMDUxdmlkILVaqZLlLyfSGbX3PIZUPfKdwVCmGyfb79lP2J8HUU1yQ-rbxcg28P4XAS08P5NCOMq8N8soheTseUvbXhAN7Q7cvXZNzaCf2gowMDFiY2wgaHR0cDovL2F1dGgubXliYW5rLwowMDJmc2lnbmF0dXJlIGBezWqD1UAVoap5EOr7q-hYepUUeRE-GiyUq82Eopg_Cg'
	% >>> DP.serialize()
	% 'MDAyMWxvY2F0aW9uIGh0dHA6Ly9hdXRoLm15YmFuay8KMDAzN2lkZW50aWZpZXIgdGhpcyB3YXMgaG93IHdlIHJlbWluZCBhdXRoIG9mIGtleS9wcmVkCjAwMjBjaWQgdGltZSA8IDIwMjAtMDEtMDFUMDA6MDAKMDAyZnNpZ25hdHVyZSBxp6zFSsFEjO9XPVEQeqngTREtoMNvDY-z7t3pDQhXnwo'
	% >>>
	% >>> print M.inspect()
	% location http://mybank/
	% identifier we used our other secret key
	% cid account = 3735928559
	% cid this was how we remind auth of key/pred
	% vid tVqpkuUvJ9IZtfc8hlQ98p3BUKYbJ9vv2U_YnwdRTXJD6tvFyDbw_hcBLTw_k0I4yrw3yyiF5Ox5S9teEA3tDty9dk3NoJ_a
	% cl http://auth.mybank/
	% signature 605ecd6a83d54015a1aa7910eafbabe8587a951479113e1a2c94abcd84a2983f
	% 
	% >>> print D.inspect()
	% location http://auth.mybank/
	% identifier this was how we remind auth of key/pred
	% cid time < 2020-01-01T00:00
	% signature 2ed1049876e9d5840950274b579b0770317df54d338d9d3039c7c67d0d91d63c
	% 
    %
    %
    %-------------- TEST -----------------------
	MData = <<"MDAxY2xvY2F0aW9uIGh0dHA6Ly9teWJhbmsvCjAwMmNpZGVudGlmaWVyIHdlIHVzZWQgb3VyIG90aGVyIHNlY3JldCBrZXkKMDAxZGNpZCBhY2NvdW50ID0gMzczNTkyODU1OQowMDMwY2lkIHRoaXMgd2FzIGhvdyB3ZSByZW1pbmQgYXV0aCBvZiBrZXkvcHJlZAowMDUxdmlkILVaqZLlLyfSGbX3PIZUPfKdwVCmGyfb79lP2J8HUU1yQ-rbxcg28P4XAS08P5NCOMq8N8soheTseUvbXhAN7Q7cvXZNzaCf2gowMDFiY2wgaHR0cDovL2F1dGgubXliYW5rLwowMDJmc2lnbmF0dXJlIGBezWqD1UAVoap5EOr7q-hYepUUeRE-GiyUq82Eopg_Cg">>,
	DPData = <<"MDAyMWxvY2F0aW9uIGh0dHA6Ly9hdXRoLm15YmFuay8KMDAzN2lkZW50aWZpZXIgdGhpcyB3YXMgaG93IHdlIHJlbWluZCBhdXRoIG9mIGtleS9wcmVkCjAwMjBjaWQgdGltZSA8IDIwMjAtMDEtMDFUMDA6MDAKMDAyZnNpZ25hdHVyZSBxp6zFSsFEjO9XPVEQeqngTREtoMNvDY-z7t3pDQhXnwo">>,

	Key = <<"this is a different super-secret key; never use the same secret twice">>,
	M = deserialize(MData),
	DP = deserialize(DPData),


	D = create(<<"http://auth.mybank/">>,<<"this was how we remind auth of key/pred">>,<<"4; guaranteed random by a fair toss of the dice">>),
	D1 = add_first_party_caveat(<<"time < 2020-01-01T00:00">>,D),


	ExpMacInspect = <<"location http://mybank/\nidentifier we used our other secret key\ncid account = 3735928559\ncid this was how we remind auth of key/pred\nvid tVqpkuUvJ9IZtfc8hlQ98p3BUKYbJ9vv2U_YnwdRTXJD6tvFyDbw_hcBLTw_k0I4yrw3yyiF5Ox5S9teEA3tDty9dk3NoJ_a\ncl http://auth.mybank/\nsignature 605ecd6a83d54015a1aa7910eafbabe8587a951479113e1a2c94abcd84a2983f\n">>,
    ExpD1Inspect = <<"location http://auth.mybank/\nidentifier this was how we remind auth of key/pred\ncid time < 2020-01-01T00:00\nsignature 2ed1049876e9d5840950274b579b0770317df54d338d9d3039c7c67d0d91d63c\n">>,

    ExpMacInspect = inspect(M),
    ExpD1Inspect = inspect(D1),

	% cover as many possible ways as possible
	{error,badarg} = prepare_for_request(D1,M),

	D2 = prepare_for_request(M,D1),
	true = (get_signature(DP) =:= get_signature(D2)),

	V = create_verifier(),
	V1 = add_exact_satisfy(<<"account = 3735928559">>,V), 
	TimeSatisfy = fun(Predicate) -> 
		 	<<"time">> =:= lists:nth(1,binary:split(Predicate,[<<" < ">>],[trim]))
	end,
	V2 = add_general_satisfy(<<"Time">>,TimeSatisfy,V1),
	true = verify(M,Key,[DP],V2),

	% change the signature so the third caveat signature check will fail
	M2 = M#macaroon{signature= <<"this will fail">>},
	false = verify(M2,Key,[DP],V2),
	ok.

deserialize_multiple_test() ->
	MData = <<"MDAxY2xvY2F0aW9uIGh0dHA6Ly9teWJhbmsvCjAwMmNpZGVudGlmaWVyIHdlIHVzZWQgb3VyIG90aGVyIHNlY3JldCBrZXkKMDAxZGNpZCBhY2NvdW50ID0gMzczNTkyODU1OQowMDMwY2lkIHRoaXMgd2FzIGhvdyB3ZSByZW1pbmQgYXV0aCBvZiBrZXkvcHJlZAowMDUxdmlkILVaqZLlLyfSGbX3PIZUPfKdwVCmGyfb79lP2J8HUU1yQ-rbxcg28P4XAS08P5NCOMq8N8soheTseUvbXhAN7Q7cvXZNzaCf2gowMDFiY2wgaHR0cDovL2F1dGgubXliYW5rLwowMDJmc2lnbmF0dXJlIGBezWqD1UAVoap5EOr7q-hYepUUeRE-GiyUq82Eopg_Cg">>,
	DPData = <<"MDAyMWxvY2F0aW9uIGh0dHA6Ly9hdXRoLm15YmFuay8KMDAzN2lkZW50aWZpZXIgdGhpcyB3YXMgaG93IHdlIHJlbWluZCBhdXRoIG9mIGtleS9wcmVkCjAwMjBjaWQgdGltZSA8IDIwMjAtMDEtMDFUMDA6MDAKMDAyZnNpZ25hdHVyZSBxp6zFSsFEjO9XPVEQeqngTREtoMNvDY-z7t3pDQhXnwo">>,

    MultipleData = << MData/binary, <<", ">>/binary, DPData/binary >>,
    [M,D1] = deserialize_multiple(MultipleData),

	ExpMacInspect = <<"location http://mybank/\nidentifier we used our other secret key\ncid account = 3735928559\ncid this was how we remind auth of key/pred\nvid tVqpkuUvJ9IZtfc8hlQ98p3BUKYbJ9vv2U_YnwdRTXJD6tvFyDbw_hcBLTw_k0I4yrw3yyiF5Ox5S9teEA3tDty9dk3NoJ_a\ncl http://auth.mybank/\nsignature 605ecd6a83d54015a1aa7910eafbabe8587a951479113e1a2c94abcd84a2983f\n">>,
    ExpD1Inspect = <<"location http://auth.mybank/\nidentifier this was how we remind auth of key/pred\ncid time < 2020-01-01T00:00\nsignature 71a7acc54ac1448cef573d51107aa9e04d112da0c36f0d8fb3eedde90d08579f\n">>,
    ExpMacInspect = inspect(M),
    ExpD1Inspect = inspect(D1),
    ok.

-endif. 
