%%%=============================================================================
%% @doc Schema definitions cache handling.
%%
%% All the schema definitions are stored in an ETS table for quick access during
%% validation. This module provides an interface for: 1) updating of schema
%% definitions in runtime; 2) getting of a schema definition by a key. When
%% an update is ordered, the update function checks a schema definition file
%% timestamp and compares it to a timestamp for the same schema in the 'cache',
%% so, it will never update a schema in the database if the definition file
%% was not updated.
%% @end
%%%=============================================================================

-module(jesse_database).

%% API
-export([ read_schema/1
        , update/4
        ]).

-export_type([ update_result/0
             ]).

-type update_result() :: ok | [fail()].

-type fail()          :: {file:filename(), file:date_time(), reason()}.
-type reason()        :: term().

-define(JESSE_ETS, jesse_ets).

-include_lib("kernel/include/file.hrl").

%%% API
%% @doc Updates schema definitions in in-memory storage. The function loads all
%% the files from directory `Path', then each schema entry will be checked
%% for a validity by function `ValidationFun', and will be stored in in-memory
%% storage with a key returned by `MakeKeyFun' function.
%%
%% In addition to a schema definition, a timestamp of the schema file will be
%% stored, so, during the next update timestamps will be compared to avoid
%% unnecessary updates.
%%
%% Schema definitions are stored in the format which json parsing function
%% `ParseFun' returns.
-spec update( Path          :: string()
            , ParseFun      :: fun((any()) -> jesse:json_term())
            , ValidationFun :: fun((any()) -> boolean())
            , MakeKeyFun    :: fun((jesse:json_term()) -> any())
            ) -> update_result().
update(Path, ParseFun, ValidationFun, MakeKeyFun) ->
  Schemas = load_schema(Path, get_updated_files(Path), ParseFun),
  store_schema(Schemas, ValidationFun, MakeKeyFun).

%% @doc Reads a schema definition with the same key as `Key' from the internal
%% storage. If there is no such key in the storage, an exception will be thrown.
-spec read_schema(Key :: any()) -> jesse:json_term() | no_return().
read_schema(Key) ->
  case ets:lookup(table_name(), Key) of
    [{Key, _SecondaryKey, _TimeStamp, Term}] ->
      Term;
    _ ->
      throw({database_error, Key, schema_not_found})
  end.

%%% Internal functions
%% @doc Stores schema definitions `Schemas' in in-memory storage.
%% Uses `ValidationFun' to validate each schema definition before it is stored.
%% Each schema definition is stored with a key returned by `MakeKeyFun' applied
%% to the schema entry. Returns `ok' in case if all the schemas passed
%% the validation and were stored, otherwise a list of invalid entries
%% is returned.
%% @private
store_schema(Schemas, ValidationFun, MakeKeyFun) ->
  Table    = create_table(table_name()),
  StoreFun = fun({InFile, TimeStamp, Value} = Object, Acc) ->
                 case ValidationFun(Value) of
                   true ->
                     NewObject = { MakeKeyFun(Value)
                                 , get_secondary_key(InFile)
                                 , TimeStamp
                                 , Value
                                 },
                     ets:insert(Table, NewObject),
                     Acc;
                   false ->
                     [Object | Acc]
                 end
             end,
  store_result(lists:foldl(StoreFun, [], Schemas)).

%% @private
store_result([])    -> ok;
store_result(Fails) -> Fails.

%% @doc Creates ETS table for internal cache if it does not exist yet,
%% otherwise the name of the table is returned.
%% @private
create_table(TableName) ->
  case table_exists(TableName) of
    false -> ets:new(TableName, [set, public, named_table]);
    true -> TableName
  end.

%% @doc Checks if ETS table with name `TableName' exists.
%% @private
table_exists(TableName) ->
  case ets:info(TableName) of
    undefined -> false;
    _TableInfo -> true
  end.

%% @doc Returns a list of schema definitions files in `InDir' which need to be
%% updated in the cache.
%% @private
get_updated_files(InDir) ->
  case { get_file_list(InDir)
       , table_exists(table_name())
       } of
    {[] = Files, _TableExists} ->
      Files;
    {Files, false} ->
      Files;
    {Files, _TableExists} ->
      Filter = fun(InFile) ->
                   is_outdated( get_full_path(InDir, InFile)
                              , get_secondary_key(InFile)
                              )
               end,
      lists:filter(Filter, Files)
  end.

%% @doc Returns a secondary key for the cache storage, based on a schema
%% definition file name. This key will be used during cache updates.
%% @private
get_secondary_key(InFile) ->
  filename:rootname(InFile).

%% @doc Loads schema definitions from a list of files `Files' located in
%% directory `InDir', and parses each of entry by the given parse
%% function `ParseFun'.
%% @private
load_schema(InDir, Files, ParseFun) ->
  LoadFun = fun(InFile) ->
                InFilePath      = get_full_path(InDir, InFile),
                {ok, SchemaBin} = file:read_file(InFilePath),
                {ok, FileInfo}  = file:read_file_info(InFilePath),
                TimeStamp       = FileInfo#file_info.mtime,
                Schema          = try_parse(ParseFun, SchemaBin),
                {InFile, TimeStamp, Schema}
            end,
  lists:map(LoadFun, Files).

%% @doc Wraps up calls to a third party json parser.
%% @private
try_parse(ParseFun, SchemaBin) ->
  try
    ParseFun(SchemaBin)
  catch
    _:Error ->
      {parse_error, Error}
  end.

%% @private
get_file_list(InDir) ->
  {ok, Files} = file:list_dir(InDir),
  Files.

%% @private
get_full_path(Dir, File) ->
  filename:join([Dir, File]).

%% @doc Checks if a cache entry for a schema definition from file `InFile'
%% is outdated. Returns `true' if the cache entry needs to be updated, or if
%% the entry does not exist in the cache, otherwise `false' is returned.
%% @private
is_outdated(InFile, SecondaryKey) ->
  case ets:lookup(table_name(), {'_', SecondaryKey, '_', '_'}) of
    [] ->
      true;
    [{_Key, SecondaryKey, TimeStamp, _Value}] ->
      {ok, #file_info{mtime = MtimeIn}} = file:read_file_info(InFile),
      MtimeIn > TimeStamp
  end.

%% @doc Returns a name of ETS table which is used for in-memory cache.
%% Could be rewritten to use a configuration parameter instead of a hardcoded
%% value.
%% @private
table_name() -> ?JESSE_ETS.

%%% Local Variables:
%%% erlang-indent-level: 2
%%% End: