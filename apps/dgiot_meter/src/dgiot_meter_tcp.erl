%%--------------------------------------------------------------------
%% Copyright (c) 2020 DGIOT Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------
-module(dgiot_meter_tcp).
-author("johnliu").
-include_lib("dgiot/include/dgiot_socket.hrl").
-include_lib("dgiot/include/logger.hrl").
-include("dgiot_meter.hrl").
%% API
-export([start/2]).

%% TCP callback
-export([init/1, handle_info/2, handle_cast/2, handle_call/3, terminate/2, code_change/3]).

start(Port, State) ->
    dgiot_tcp_server:child_spec(?MODULE, dgiot_utils:to_int(Port), State).

%% =======================
%% tcp server start
%% {ok, State} | {stop, Reason}
init(TCPState) ->
    dgiot_metrics:inc(dgiot_meter, <<"dtu_login">>, 1),
    {ok, TCPState}.

%%设备登录报文，登陆成功后，开始搜表
handle_info({tcp, Buff}, #tcp{socket = Socket, state = #state{id = ChannelId, dtuaddr = <<>>, search = Search} = State} = TCPState) ->
    DTUIP = dgiot_utils:get_ip(Socket),
    NewBuff =
        case is_binary(Buff) of
            true -> dgiot_utils:binary_to_hex(Buff);
            false -> Buff
        end,
    {DtuProductId, _, _} = dgiot_data:get({dtu, ChannelId}),
    dgiot_bridge:send_log(ChannelId, DtuProductId, NewBuff, "(登录) ~p ", [NewBuff]),
    {Protocol, DtuAddr} =
        case Buff of
            <<16#68, _:4/bytes, 16#68, _A1:8/bytes, _Rest/binary>> ->
                {_, [Acc | _]} = dlt376_decoder:parse_frame(Buff, []),  %% NewBuff
                #{<<"msgtype">> := Protocol1, <<"con">> := Con, <<"addr">> := MeterAddr} = Acc,
                case Con of
                    1 ->
                        Frame = maps:get(<<"frame">>, Acc, <<>>),
                        dgiot_tcp_server:send(TCPState, Frame);
                    _ -> ok
                end,
                dgiot_meter:create_meter4G(MeterAddr, ChannelId, DTUIP),
                {Protocol1, MeterAddr};
            _ ->
                {?DLT645, Buff}
        end,
    case Protocol of
        ?DLT376 ->
            {ProductId, _, _} = dgiot_data:get({dtu, ChannelId}),
            Topic = <<"thing/", ProductId/binary, "/", DtuAddr/binary>>,
            dgiot_mqtt:subscribe(Topic),  %为这个设备订阅一个mqtt
            dgiot_bridge:send_log(ChannelId, ProductId, DtuAddr, "from dev ~p (登录)", [dgiot_utils:binary_to_hex(Buff)]),
            {NewRef, NewStep} = {undefined, read_meter},
            DtuId = dgiot_parse:get_deviceid(DtuProductId, DtuAddr),
            case Search of
                <<"nosearch">> ->
                    lists:map(fun(X) ->
                        case X of
                            #{<<"product">> := #{<<"objectId">> := MeterProductid}, <<"devaddr">> := Meteraddr,<<"route">> := Route} ->
                                dgiot_bridge:send_log(ChannelId, MeterProductid, Meteraddr, "save taskque MeterProductid ~p  Meteraddr ~p", [MeterProductid, Meteraddr]),
                                dgiot_data:insert({concentrator, MeterProductid, Meteraddr}, Route),
                                dgiot_task:save_pnque(DtuProductId, DtuAddr, MeterProductid, Meteraddr);
                            _ ->
                                pass
                        end
                              end, dgiot_meter:get_sub_device(DtuAddr));
                _ ->
                    pass
            end,
            dgiot_metrics:inc(dgiot_meter, <<"dtu_online">>, 1),
            {noreply, TCPState#tcp{buff = <<>>, register = true, clientid = DtuId, state = State#state{dtuaddr = DtuAddr, protocol = ?DLT376,ref = NewRef, step = NewStep}}};
        ?DLT645 ->
            dgiot_meter:create_dtu(DtuAddr, ChannelId, DTUIP),
            {DtuProductId, _, _} = dgiot_data:get({dtu, ChannelId}),
            Topic = <<"profile/", DtuProductId/binary, "/", DtuAddr/binary>>,
            dgiot_mqtt:subscribe(Topic),
            {NewRef, NewStep} =
                case Search of
                    <<"nosearch">> ->
                        lists:map(fun(X) ->
                            case X of
                                #{<<"product">> := #{<<"objectId">> := MeterProductid}, <<"devaddr">> := Meteraddr} ->
                                    dgiot_bridge:send_log(ChannelId, MeterProductid, Meteraddr, "save taskque Meteraddr ~p", [Meteraddr]),
                                    dgiot_task:save_pnque(DtuProductId, DtuAddr, MeterProductid, Meteraddr);
                                _ ->
                                    pass
                            end
                                  end, dgiot_meter:get_sub_device(DtuAddr)),
                        {undefined, read_meter};
                    <<"quick">> ->
                        dgiot_meter:search_meter(tcp, undefined, TCPState, 0),
                        {undefined, search_meter};
                    _ ->
                        {Ref, Step, _Payload} = dgiot_meter:search_meter(tcp, undefined, TCPState, 1),
                        {Ref, Step}
                end,
                dgiot_bridge:send_log(ChannelId, DtuProductId, DtuAddr, "from dev ~p (登录)", [dgiot_utils:binary_to_hex(DtuAddr)]),
                DtuId = dgiot_parse:get_deviceid(DtuProductId, DtuAddr),
                dgiot_metrics:inc(dgiot_meter, <<"dtu_online">>, 1),
            {noreply, TCPState#tcp{buff = <<>>, register = true, clientid = DtuId, state = State#state{dtuaddr = DtuAddr, protocol = ?DLT645, ref = NewRef, step = NewStep}}}
    end;

%%定时器触发搜表
handle_info(search_meter, #tcp{state = #state{ref = Ref, protocol = ?DLT645} = State} = TCPState) ->
    {NewRef, Step, _Payload} = dgiot_meter:search_meter(tcp, Ref, TCPState, 1),
    {noreply, TCPState#tcp{buff = <<>>, state = State#state{ref = NewRef, step = Step}}};

%%ACK报文触发搜表
handle_info({tcp, Buff}, #tcp{socket = Socket, state = #state{id = ChannelId, dtuaddr = DtuAddr, protocol = ?DLT645, ref = Ref, step = search_meter, search = Search} = State} = TCPState) ->
    dgiot_metrics:inc(dgiot_meter, <<"search_meter">>, 1),
    {DtuProductId, _, _} = dgiot_data:get({dtu, ChannelId}),
    dgiot_bridge:send_log(ChannelId, DtuProductId, DtuAddr, "from dev ~p (搜表成功)", [dgiot_utils:binary_to_hex(Buff)]),
    {Rest, Frames} = dgiot_meter:parse_frame(?DLT645, Buff, []),
    lists:map(fun(X) ->
        case X of
            #{<<"addr">> := Addr} ->
                DTUIP = dgiot_utils:get_ip(Socket),
                dgiot_meter:create_meter(dgiot_utils:binary_to_hex(Addr), ChannelId, DTUIP, DtuAddr);
            Other ->
                ?LOG(info, "Other ~p", [Other]),
                pass %%异常报文丢弃
        end
              end, Frames),
    case Search of
        <<"normal">> ->
            {NewRef, Step, _Payload} = dgiot_meter:search_meter(tcp, Ref, TCPState, 1),
            {noreply, TCPState#tcp{buff = Rest, state = State#state{ref = NewRef, step = Step}}};
        _ ->
            case length(Frames) > 0 of
                true ->
                    {noreply, TCPState#tcp{buff = Rest, state = State#state{ref = undefined, step = read_meter}}};
                false ->
                    {noreply, TCPState#tcp{buff = Rest, state = State#state{ref = undefined, step = search_meter}}}
            end
    end;

handle_info({tcp, Buff}, #tcp{state = #state{id = ChannelId, protocol = Protocol, step = _Step}} = TCPState) ->
    case Protocol of
        ?DLT376 ->
            dgiot_bridge:send_log(ChannelId, "from_dev:  ~p ", [dgiot_utils:binary_to_hex(Buff)]),
            {Rest, Frames} = dgiot_meter:parse_frame(?DLT376, Buff, []),
            case Frames of
                [#{<<"con">> := 1} = Frame | _] ->
                    Frame1 = maps:get(<<"frame">>, Frame, <<16#68>>),
                    dgiot_tcp_server:send(TCPState, Frame1);
                _ -> ok
            end,
            dlt376_decoder:process_message(Frames, ChannelId),
            {noreply, TCPState#tcp{buff = Rest}};
        ?DLT645 ->
            {Rest, Frames} = dgiot_meter:parse_frame(?DLT645, Buff, []),
            dgiot_bridge:send_log(ChannelId, "from_dev: Rest ~p Frames ~p ", [Rest, Frames]),
            dlt645_decoder:process_message(Frames, ChannelId),
            {noreply, TCPState#tcp{buff = Rest}};
        _ ->
            {noreply, TCPState#tcp{buff = <<0, 0, 0, 0, 0, 0, 0, 0>>}}
    end;

%%接受抄表任务命令抄表(下发指令)
handle_info({deliver, _Topic, Msg}, #tcp{state = #state{id = _ChannelId}} = TCPState) ->
    Payload = dgiot_mqtt:get_payload(Msg),
    dgiot_metrics:inc(dgiot_meter, <<"mqtt_revc">>, 1),
    case jsx:is_json(Payload) of
        true ->
            case binary:split(dgiot_mqtt:get_topic(Msg), <<$/>>, [global, trim]) of
                [<<"thing">>, ProductId, DevAddr] ->
                    #tcp{state = #state{protocol = Protocol}} = TCPState,
                    case Protocol of
                        ?DLT376 ->
                            Route = dgiot_data:get({concentrator, ProductId, DevAddr}),
                            ?LOG(info,"Route ~p ",[Route]),
                            [#{<<"thingdata">> := ThingData} | _] = jsx:decode(dgiot_mqtt:get_payload(Msg), [{labels, binary}, return_maps]),
                            Payload1 = dgiot_meter:to_frame(ThingData),
                            dgiot_tcp_server:send(TCPState, Payload1);
                        ?DLT645 ->
                            [#{<<"thingdata">> := ThingData} | _] = jsx:decode(dgiot_mqtt:get_payload(Msg), [{labels, binary}, return_maps]),
                            Payload1 = dgiot_meter:to_frame(ThingData),
                            dgiot_tcp_server:send(TCPState, Payload1)
                    end;
                [<<"profile">>, _ProductId, _DevAddr] ->
                    case Payload of
                        #{<<"_dgiotprotocol">> := <<"hex">>} ->
                            maps:fold(fun(_K, V, Acc) ->
                                dgiot_tcp_server:send(TCPState, dgiot_utils:hex_to_binary(V)),
                                Acc
                                      end, #{}, maps:without([<<"_dgiotprotocol">>], Payload));
                        _ ->
                            pass
                    end;
                [<<"thingctrl">>, _ProductId, _DevAddr] ->
                    #tcp{state = #state{protocol = Protocol}} = TCPState,
                    case Protocol of
                        ?DLT376 ->
                            [#{<<"thingdata">> := ThingData} | _] = jsx:decode(dgiot_mqtt:get_payload(Msg), [{labels, binary}, return_maps]),
                            case ThingData of
                                % 远程控制电表拉闸、合闸
                                #{<<"devaddr">> := DevAddr, <<"ctrlflag">> := CtrlFlag, <<"devpass">> := DevPass, <<"apiname">> := <<"get_meter_ctrl">>} ->
                                    ThingData1 = #{<<"devaddr">> => DevAddr, <<"ctrlflag">> => CtrlFlag, <<"devpass">> => DevPass, <<"protocol">> => Protocol, <<"apiname">> => get_meter_ctrl},
                                    Payload1 = dgiot_meter:to_frame(ThingData1),
                                    dgiot_tcp_server:send(TCPState, Payload1);
                                % 获取上次拉闸、合闸的时间（一次发送两条查询指令）
                                #{<<"devaddr">> := DevAddr, <<"ctrlflag">> := CtrlFlag, <<"apiname">> := <<"get_meter_ctrl_status">>} ->
                                    % 上次合闸时间
                                    ThingData1 = #{<<"devaddr">> => DevAddr, <<"ctrlflag">> => CtrlFlag, <<"protocol">> => Protocol, <<"apiname">> => get_meter_ctrl_status},
                                    Payload1 = dgiot_meter:to_frame(ThingData1),
                                    dgiot_tcp_server:send(TCPState, Payload1);
                                _ ->
                                    pass
                            end;
                        ?DLT645 ->
                            [#{<<"thingdata">> := ThingData} | _] = jsx:decode(dgiot_mqtt:get_payload(Msg), [{labels, binary}, return_maps]),
                            case ThingData of
                                % 远程控制电表拉闸、合闸
                                #{<<"devaddr">> := DevAddr, <<"ctrlflag">> := CtrlFlag, <<"devpass">> := DevPass, <<"apiname">> := <<"get_meter_ctrl">>} ->
                                    % ?LOG(info, "GGM 212 dgiot_meter_tcp, handle_info9 ~p,~p,~p,~p",[DevAddr,CtrlFlag,DevPass,Protocol]),
                                    ThingData1 = #{<<"devaddr">> => DevAddr, <<"ctrlflag">> => CtrlFlag, <<"devpass">> => DevPass, <<"protocol">> => Protocol, <<"apiname">> => get_meter_ctrl},
                                    Payload1 = dgiot_meter:to_frame(ThingData1),
                                    dgiot_tcp_server:send(TCPState, Payload1);
                                % 获取上次拉闸、合闸的时间（一次发送两条查询指令）
                                #{<<"devaddr">> := DevAddr, <<"ctrlflag">> := CtrlFlag, <<"apiname">> := <<"get_meter_ctrl_status">>} ->
                                    ThingData1 = #{<<"devaddr">> => DevAddr, <<"ctrlflag">> => CtrlFlag, <<"protocol">> => Protocol, <<"apiname">> => get_meter_ctrl_status},
                                    Payload1 = dgiot_meter:to_frame(ThingData1),
                                    dgiot_tcp_server:send(TCPState, Payload1);
                                _ ->
                                    pass
                            end
                    end;
                _ ->
                    pass
            end;
        false -> pass
    end,
    {noreply, TCPState};


%% 异常报文丢弃
%% {stop, TCPState} | {stop, Reason} | {ok, TCPState} | ok | stop
handle_info(_Info, TCPState) ->
    ?LOG(info, "GGM 999 Meter Rev Buff========ERROR========= dgiot_meter_tcp, handle_info9, ~p,~p~n~n~n ", [_Info, TCPState]),
    {noreply, TCPState}.

handle_call(_Msg, _From, TCPState) ->
    {reply, ok, TCPState}.

handle_cast(_Msg, TCPState) ->
    {noreply, TCPState}.

terminate(_Reason, _TCPState) ->
    dgiot_metrics:dec(dgiot_meter, <<"dtu_online">>, 1),
    ok.

code_change(_OldVsn, TCPState, _Extra) ->
    {ok, TCPState}.
