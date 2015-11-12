%%
-module(vg_log).
-behaviour(gen_server).

-export([start_link/2,
         write/3]).

-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-record(config, {log_dir              :: file:filename(),
                 segment_bytes        :: integer(),
                 index_max_bytes      :: integer(),
                 index_interval_bytes :: integer()}).

-record(state, {topic_dir   :: file:filename(),
                id          :: integer(),
                byte_count  :: integer(),
                pos         :: integer(),
                index_pos   :: integer(),
                log_fd      :: file:fd(),
                segment_id  :: integer(),
                index_fd    :: file:fd(),
                topic       :: binary(),
                partition   :: integer(),

                config      :: #config{}
               }).

start_link(Topic, Partition) ->
    gen_server:start_link({via, gproc, {n,l,{?MODULE,Topic,Partition}}}, ?MODULE, [Topic, Partition], []).

-spec write(Topic, Partition, MessageSet) -> ok when
      Topic :: binary(),
      Partition :: integer(),
      MessageSet :: [binary()].
write(Topic, Partition, MessageSet) ->
    gen_server:call({via, gproc, {n,l,{?MODULE, Topic, Partition}}}, {write, MessageSet}).

init([Topic, Partition]) ->
    Config = setup_config(),

    LogDir = Config#config.log_dir,
    TopicDir = filename:join(LogDir, [binary_to_list(Topic), "-", integer_to_list(Partition)]),
    filelib:ensure_dir(filename:join(TopicDir, "ensure")),

    {Id, LatestIndex, LatestLog} = find_latest_id(TopicDir, Topic, Partition),
    LastLogId = filename:basename(LatestLog, ".log"),
    {ok, LogFD} = vg_utils:open_append(LatestLog),
    {ok, IndexFD} = vg_utils:open_append(LatestIndex),

    {ok, Position} = file:position(LogFD, eof),
    {ok, IndexPosition} = file:position(IndexFD, eof),

    {ok, #state{id=Id,
                topic_dir=TopicDir,
                byte_count=0,
                pos=Position,
                index_pos=IndexPosition,
                log_fd=LogFD,
                segment_id=list_to_integer(LastLogId),
                index_fd=IndexFD,
                topic=Topic,
                partition=Partition,
                config=Config
               }}.

handle_call({write, MessageSet}, _From, State) ->
    State1 = write_message_set(MessageSet, State),
    {reply, ok, State1}.

handle_cast(_, State) ->
    {noreply, State}.

handle_info(_, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_, State, _) ->
    {ok, State}.

%% Internal functions

write_message_set(MessageSet, State=#state{id=Id,
                                           pos=Position,
                                           byte_count=ByteCount}) ->
    {NextId, Bytes} = vg_encode:message_set(Id, MessageSet),
    Size = erlang:iolist_size(Bytes),
    State1 = maybe_roll(Size, State),
    update_log(Bytes, State1),
    IndexPosition = update_index(State1),
    State1#state{id=NextId,
                 pos=Position+Size,
                 index_pos=IndexPosition,
                 byte_count=ByteCount+Size}.

%% Create new log segment and index file if current segment is too large
%% or if the index file is over its max and would be written to again.
maybe_roll(Size, State=#state{id=Id,
                              topic_dir=TopicDir,
                              log_fd=LogFile,
                              index_fd=IndexFile,
                              pos=Position,
                              byte_count=ByteCount,
                              index_pos=IndexPosition,
                              topic=Topic,
                              partition=Partition,
                              config=#config{segment_bytes=SegmentBytes,
                                             index_max_bytes=IndexMaxBytes,
                                             index_interval_bytes=IndexIntervalBytes}})
  when Position+Size > SegmentBytes
     ; ByteCount+Size >= IndexIntervalBytes
     , IndexPosition+6 > IndexMaxBytes ->
    ok = file:close(LogFile),
    ok = file:close(IndexFile),

    {NewIndexFile, NewLogFile} = new_index_log_files(TopicDir, Id),
    vg_topic_sup:start_segment(Topic, Partition, Id),

    State#state{log_fd=NewLogFile,
                index_fd=NewIndexFile,
                byte_count=0,
                pos=0,
                index_pos=0};
maybe_roll(_, State) ->
    State.

%% Append encoded log to segment
update_log(Message, #state{log_fd=LogFile}) ->
    ok = file:write(LogFile, Message).

%% Add to index if the number of bytes written to the log since the last index record was written
update_index(State=#state{id=Id,
                          pos=Position,
                          index_fd=IndexFile,
                          byte_count=ByteCount,
                          index_pos=IndexPosition,
                          segment_id=BaseOffset,
                          config=#config{index_interval_bytes=IndexIntervalBytes}})
  when ByteCount >= IndexIntervalBytes ->
    IndexEntry = <<(Id - BaseOffset):24/signed, Position:24/signed>>,
    ok = file:write(IndexFile, IndexEntry),
    State#state{index_pos=IndexPosition+6};
update_index(State) ->
    State.

%% Rolling log and index files, so open new empty ones for appending
new_index_log_files(TopicDir, Id) ->
    IndexFilename = vg_utils:index_file(TopicDir, Id),
    LogFilename = vg_utils:log_file(TopicDir, Id),

    %% Make sure empty?
    {ok, IndexFile} = vg_utils:open_append(IndexFilename),
    {ok, LogFile} = vg_utils:open_append(LogFilename),
    {IndexFile, LogFile}.

find_latest_id(TopicDir, Topic, Partition) ->
    SegmentId = vg_utils:find_active_segment(Topic, Partition),
    IndexFilename = vg_utils:index_file(TopicDir, SegmentId),
    {Offset, Position} = last_in_index(TopicDir, IndexFilename, Topic, Partition, SegmentId),
    LogSegmentFilename = vg_utils:log_file(TopicDir, SegmentId),
    {ok, Log} = vg_utils:open_read(LogSegmentFilename),
    try
        NewId = find_last_log(Log, Offset, file:pread(Log, Position, 16)),
        {NewId+SegmentId+1, IndexFilename, LogSegmentFilename}
    after
        file:close(Log)
    end.

last_in_index(TopicDir, IndexFilename, Topic, Partition, SegmentId) ->
    case vg_utils:open_read(IndexFilename) of
        {error, enoent} when SegmentId =:= 0 ->
            %% Index file doesn't exist, if this is the first segment (0)
            %% we can just create the files assuming this is a topic creation.
            %% Will fail if an empty topic-partition dir exists on boot since
            %% vg_topic_sup will not be started yet.
            {NewIndexFile, NewLogFile} = new_index_log_files(TopicDir, SegmentId),
            file:close(NewIndexFile),
            file:close(NewLogFile),
            vg_topic_sup:start_segment(Topic, Partition, SegmentId),
            {0, 0};
        {ok, Index} ->
            try
                case file:pread(Index, {eof, 6}, 6) of
                    <<Offset:24/signed, Position:24/signed>> ->
                        {Offset, Position};
                    _ ->
                        {0, 0}
                end
            after
                file:close(Index)
            end
    end.

%% Find the Id for the last log in the log file Log
find_last_log(Log, _, {ok, <<NewId:64/signed, Size:32/signed>>}) ->
    case file:read(Log, Size + 12) of
        {ok, <<_:Size/binary, Data:12/binary>>} ->
            find_last_log(Log, NewId, {ok, Data});
        _ ->
            NewId
    end;
find_last_log(_Log, Id, _) ->
    Id.

setup_config() ->
    {ok, [LogDir]} = application:get_env(vonnegut, log_dirs),
    {ok, SegmentBytes} = application:get_env(vonnegut, segment_bytes),
    {ok, IndexMaxBytes} = application:get_env(vonnegut, index_max_bytes),
    {ok, IndexIntervalBytes} = application:get_env(vonnegut, index_interval_bytes),
    #config{log_dir=LogDir,
            segment_bytes=SegmentBytes,
            index_max_bytes=IndexMaxBytes,
            index_interval_bytes=IndexIntervalBytes}.
