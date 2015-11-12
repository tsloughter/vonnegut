%%%-------------------------------------------------------------------
%% @doc vonnegut top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(vg_topic_sup).

-behaviour(supervisor).

%% API
-export([start_link/2,
         start_segment/3]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%====================================================================
%% API functions
%%====================================================================

start_link(Topic, Partitions) ->
    supervisor:start_link({via, gproc, {n,l,Topic}}, ?MODULE, [Topic, Partitions]).

-spec start_segment(Topic, Partition, SegmentId) -> supervisor:startchild_ret() when
      Topic     :: binary(),
      Partition :: integer(),
      SegmentId :: integer().
start_segment(Topic, Partition, SegmentId) ->
    supervisor:start_child(?SERVER, log_segment_childspec(Topic, Partition, SegmentId)).

%%====================================================================
%% Supervisor callbacks
%%====================================================================

%% Child :: {Id,StartFunc,Restart,Shutdown,Type,Modules}
init([Topic, Partitions]) ->

    ChildSpecs = lists:flatten([child_specs(Topic, Partition) || Partition <- Partitions]),

    {ok, {{one_for_one, 0, 1}, ChildSpecs}}.

%%====================================================================
%% Internal functions
%%====================================================================

child_specs(Topic, Partition) ->
    Segments = segments(Topic, Partition),

    %% Must start segments before partition proc so it can find which segment is active
    Segments++[#{id      => {Topic, Partition},
                 start   => {vg_log, start_link, [Topic, Partition]},
                 restart => permanent,
                 type    => worker}].

-spec segments(Topic, Partition) -> [] when
      Topic     :: binary(),
      Partition :: integer().
segments(Topic, Partition) ->
    {ok, [LogDir]} = application:get_env(vonnegut, log_dirs),
    TopicPartitionDir = filename:join(LogDir, [binary_to_list(Topic), "-", integer_to_list(Partition)]),
    LogSegments = filelib:wildcard(filename:join(TopicPartitionDir, "*.log")),
    [log_segment_childspec(Topic, Partition, list_to_integer(filename:basename(LogSegment, ".log")))
    || LogSegment <- LogSegments].

log_segment_childspec(Topic, Partition, LogSegment) ->
    #{id      => {Topic, Partition, LogSegment},
      start   => {vg_log_segment, start_link, [Topic, Partition, LogSegment]},
      restart => permanent,
      type    => worker}.
