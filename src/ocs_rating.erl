%%% ocs_rating.erl
%%% vim: ts=3
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @copyright 2016 - 2017 SigScale Global Inc.
%%% @end
%%% Licensed under the Apache License, Version 2.0 (the "License");
%%% you may not use this file except in compliance with the License.
%%% You may obtain a copy of the License at
%%%
%%%     http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing, software
%%% distributed under the License is distributed on an "AS IS" BASIS,
%%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%% See the License for the specific language governing permissions and
%%% limitations under the License.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @doc This library module implements utility functions
%%% 	for handling rating in the {@link //ocs. ocs} application.
%%%
-module(ocs_rating).
-copyright('Copyright (c) 2016 - 2017 SigScale Global Inc.').

-export([rating/5]).
-export([remove_session/2]).
-export([reserve_units/5]).

-include("ocs.hrl").

%% support deprecated_time_unit()
-define(MILLISECOND, milli_seconds).
%-define(MILLISECOND, millisecond).

-define(initial, 1).
-define(update, 2).
-define(terminate, 3).

reserve_units(SubscriberID, RequestType, UnitType, RequestAmount, MonitoryAmount) when is_list(SubscriberID) ->
	reserve_units(list_to_binary(SubscriberID), RequestType, UnitType, RequestAmount, MonitoryAmount);
reserve_units(SubscriberID, RequestType, UnitType, RequestAmount, MonitoryAmount) ->
	F = fun() ->
			case mnesia:read(subscriber, SubscriberID, read) of
				[#subscriber{buckets = Buckets, product =
						#product_instance{product = ProdID,
						characteristics = Chars}} = Subscriber] ->
					Product = mnesia:read(product, ProdID),
					Validity = proplists:get_value(validity, Chars),
					case RequestType of
						?initial ->
							reserve_units1(?initial, Product, UnitType, false, RequestAmount, MonitoryAmount, Validity, Buckets);
						_ ->
							reserve_units1(RequestType, Product, Subscriber, UnitType, true, RequestAmount, MonitoryAmount, Validity, Buckets)
					end;
				[] ->
					throw(subscriber_not_found)
			end
	end,
	case mnesia:transaction(F) of
		{atomic, out_of_credit} ->
			{error, out_of_credit};
		{atomic, {grant, GrantAmount}} ->
			{ok, GrantAmount};
		{aborted, {throw, Reason}} ->
			{error, Reason};
		{aborted, Reason} ->
			{error, Reason}
	end.
%% @hidden
reserve_units1(?initial, Product, UnitType, Flag, RequestAmount, _Used, Validity, Buckets) ->
	case determinate_units(Product, UnitType, Flag, RequestAmount, Validity, Buckets) of
		{Charged, _NewBuckets} when Charged =< 0 ->
			out_of_credit;
		{_Chraged, _NewBuckets} ->
			{grant, RequestAmount}	
	end.
reserve_units1(_, Product, Subscriber, UnitType, Flag, RequestAmount, Used, Validity, Buckets) ->
	case determinate_units(Product, UnitType, Flag, Used, Validity, Buckets) of
		{Charged, NewBuckets} when Charged =< 0 andalso Used =/= 0 ->
			mnesia:write(Subscriber#subscriber{buckets = NewBuckets}),
			out_of_credit;
		{_Charged, NewBuckets} ->	
			mnesia:write(Subscriber#subscriber{buckets = NewBuckets}),
			case determinate_units(Product, UnitType, Flag, RequestAmount, Validity, Buckets) of
				{Ch1, _NB1} when Ch1 =< 0 andalso RequestAmount =/=0  ->
					out_of_credit;
				_ ->
					{grant, RequestAmount}
			end
	end.
%% @hidden
determinate_units([#product{price = Prices}], Type, Flag, Used, Validity, Buckets) ->
	case charge(Type, Used, Flag, lists:sort(fun sort_buckets/2, Buckets)) of
		{Charged, NewBuckets} when Charged < Used ->
			PriceType = case Type of
				octets -> usage;
				seconds -> seconds
			end,
			case lists:keyfind(PriceType, #price.type, Prices) of
				#price{size = Size, amount = Price} ->
					purchase(Type, Price, Size, Used - Charged, Validity, false, NewBuckets);
				false ->
					throw(price_not_found)
			end;
		{Charged, NewBuckets} ->
			{Charged, NewBuckets}
	end.



-spec rating(SubscriberID, Final, UsageSecs, UsageOctets, Attributes) -> Return
	when
		SubscriberID :: string() | binary(),
		Final :: boolean(),
		UsageSecs :: integer(),
		UsageOctets :: integer(),
		Attributes :: [[tuple()]],
		Return :: {ok, #subscriber{}} | {out_of_credit, SessionAttributes} | {error, Reason},
		SessionAttributes :: [tuple()],
		Reason :: term().
%% @todo Test cases, handle out of credit
rating(SubscriberID, Final, UsageSecs, UsageOctets, Attributes) when is_list(SubscriberID) ->
	rating(list_to_binary(SubscriberID), Final, UsageSecs, UsageOctets, Attributes);
rating(SubscriberID, Final, UsageSecs, UsageOctets, Attributes) when is_binary(SubscriberID) ->
	F = fun() ->
			case mnesia:read(subscriber, SubscriberID, write) of
				[#subscriber{buckets = Buckets,
						session_attributes = SessionList,
						product = #product_instance{product = ProdID,
						characteristics = Chars}} = Subscriber] ->
					Validity = proplists:get_value(validity, Chars),
					case mnesia:read(product, ProdID, read) of
						[#product{price = Prices}] ->
							case lists:keyfind(usage, #price.type, Prices) of
								#price{} = Price ->
									case rating2(Price,
												Validity, UsageSecs, UsageOctets, Final, Buckets) of
										{Charged, NewBuckets} when Charged =< 0 ->
											Entry = Subscriber#subscriber{buckets = NewBuckets,
													session_attributes = []},
											mnesia:write(Entry),
											{out_of_credit, SessionList};
										{_, NewBuckets} ->
											NewSessionList = case Final of
												true ->
													remove_session(SessionList, Attributes);
												false ->
													SessionList
											end,
											Entry = Subscriber#subscriber{buckets = NewBuckets,
													session_attributes = NewSessionList},
											mnesia:write(Entry),
											Entry
									end;
								false ->
									throw(price_not_found)
							end;
						[] ->
							throw(product_not_found)
					end;
				[] ->
					throw(subscriber_not_found)
			end
	end,
	case mnesia:transaction(F) of
		{atomic, #subscriber{} = Sub} ->
			{ok, Sub};
		{atomic, {out_of_credit, SL}} ->
			{out_of_credit, SL};
		{aborted, {throw, Reason}} ->
			{error, Reason};
		{aborted, Reason} ->
			{error, Reason}
	end.
%% @hidden
rating2(#price{type = usage, size = Size, units = octets,
		amount = Amount}, Validity, _UsageSecs, UsageOctets, Final, Buckets) ->
	rating3(Amount, Size, octets, Validity, UsageOctets, Final, Buckets);
rating2(#price{type = usage, size = Size, units = seconds,
		amount = Amount}, Validity, UsageSecs, _UsageOctets, Final, Buckets) ->
	rating3(Amount, Size, seconds, Validity, UsageSecs, Final, Buckets).
%% @hidden
rating3(Price, Size, Type, Validity, Used, Final, Buckets) ->
	case charge(Type, Used, Final, lists:sort(fun sort_buckets/2, Buckets)) of
		{Charged, NewBuckets} when Charged < Used ->
			purchase(Type, Price, Size, Used - Charged, Validity, Final, NewBuckets);
		{Charged, NewBuckets} ->
			{Charged, NewBuckets}
	end.

%%----------------------------------------------------------------------
%%  internal functions
%%----------------------------------------------------------------------
-spec charge(Type, Charge, Final, Buckets) -> Result
	when
		Type :: octets | seconds | cents,
		Charge :: integer(),
		Final :: boolean(),
		Buckets :: [#bucket{}],
		Result :: {Charged, Buckets},
		Charged :: integer().
charge(Type, Charge, Final, Buckets) ->
	Now = erlang:system_time(?MILLISECOND),
	charge(Type, Charge, Now, Final, Buckets, [], 0).
%% @hidden
charge(Type, Charge, Now, Final, [#bucket{bucket_type = Type,
		termination_date = T1} | T], Acc, Charged) when T1 =/= undefined, T1 =< Now->
	charge(Type, Charge, Now, Final, T, Acc, Charged);
charge(Type, Charge, _Now, true, [#bucket{bucket_type = Type,
		remain_amount = R} = B | T], Acc, Charged) when R > Charge ->
	NewBuckets = [B#bucket{remain_amount = R - Charge} | T],
	{Charged + Charge, NewBuckets ++ Acc};
charge(Type, Charge, _Now, false, [#bucket{bucket_type = Type,
		remain_amount = R} | _] = B, Acc, Charged) when R > Charge ->
	{Charged + Charge, B ++ Acc};
charge(Type, Charge, Now, true, [#bucket{bucket_type = Type,
		remain_amount = R} | T], Acc, Charged) when R =< Charge ->
	charge(Type, Charge - R, Now, true, T, Acc, Charged + R);
charge(Type, Charge, Now, false, [#bucket{bucket_type = Type,
		remain_amount = R}  = B | T], Acc, Charged) when R =< Charge ->
	charge(Type, Charge - R, Now, false, T, [B | Acc], Charged);
charge(_Type, 0, _Now, _Final, Buckets, Acc, Charged) ->
	{Charged, Buckets ++ Acc};
charge(_Type, _Charge, _Now, _Final, [], Acc, Charged) ->
	{Charged, Acc};
charge(_Type, _Charge, _Now, _Final, Buckets, Acc, Charged) ->
	{Charged, Buckets ++ Acc}.

-spec purchase(Type, Price, Size, Used, Validity, Final, Buckets) -> Result
	when
		Type :: octets | seconds,
		Price :: integer(),
		Size :: integer(),
		Used :: integer(),
		Validity :: integer(),
		Final :: boolean(),
		Buckets :: [#bucket{}],
		Result :: {Charged, Buckets},
		Charged :: integer().
purchase(Type, Price, Size, Used, Validity, Final, Buckets) ->
	UnitsNeeded = case (Used rem Size) of
		0 ->
			Used div Size;
		_ ->
			(Used div Size) + 1
	end,
	Charge = UnitsNeeded * Price,
	case charge(cents, Charge, Final, Buckets) of
		{Charged, NewBuckets} when Charged < Charge ->
			{Charged, NewBuckets};
		{Charged, NewBuckets} ->
			Remain = UnitsNeeded * Size - Used,
			Bucket = #bucket{bucket_type = Type, remain_amount = Remain,
				termination_date = Validity,
				start_date = erlang:system_time(?MILLISECOND)},
			{Charged, [Bucket | NewBuckets]}
	end.

%% @hidden
sort_buckets(#bucket{termination_date = T1}, #bucket{termination_date = T2}) when
		T1 =< T2->
	true;
sort_buckets(_, _)->
	false.

remove_session(SessionList, [H | T]) ->
	remove_session1(remove_session(SessionList, T), H);
remove_session(SessionList, []) ->
	SessionList.
%% @hidden
remove_session1(SessionList, [Candidate | T]) ->
	remove_session1(remove_session2(SessionList, Candidate), T);
remove_session1(SessionList, []) ->
	SessionList.
%% @hidden
remove_session2(SessionList, Candidate) ->
	F = fun({Ts, IsCandidate}, Acc)  ->
				case lists:member(Candidate, IsCandidate) of
					true ->
						Acc;
					false ->
						[{Ts, IsCandidate} | Acc]
				end;
		(IsCandidate, Acc)  ->
				case lists:member(Candidate, IsCandidate) of
					true ->
						Acc;
					false ->
						[IsCandidate | Acc]
				end
	end,
	lists:foldl(F, [], SessionList).

