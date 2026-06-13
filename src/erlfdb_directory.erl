% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

-module(erlfdb_directory).

-define(DOCATTRS, ?OTP_RELEASE >= 27).

-if(?DOCATTRS).
-moduledoc """
[Directory Layer](https://apple.github.io/foundationdb/developer-guide.html#directories)
""".
-endif.

-export([
    root/0,
    root/1,

    create_or_open/3,
    create_or_open/4,
    create/3,
    create/4,
    open/3,
    open/4,

    list/2,
    list/3,

    exists/2,
    exists/3,

    move/4,
    move_to/3,

    remove/2,
    remove/3,
    remove_if_exists/2,
    remove_if_exists/3,

    get_id/1,
    get_name/1,
    get_root/1,
    get_root_for_path/2,
    get_node_prefix/1,
    get_path/1,
    get_layer/1,
    get_subspace/1,

    adj_path/2,

    subspace/2,
    key/1,
    pack/2,
    pack_vs/2,
    unpack/2,
    range/1,
    range/2,
    contains/2,

    debug_nodes/2
]).

-include("erlfdb.hrl").

-define(LAYER_VERSION, {1, 0, 0}).
-define(DEFAULT_NODE_PREFIX, <<16#FE>>).
-define(SUBDIRS, 0).

-type path_item() :: binary() | {utf8, binary()}.
-type path() :: path_item() | list() | tuple().

-type root_option() ::
    {node_prefix, binary()}
    | {content_prefix, binary()}
    | {allow_manual_names, boolean()}.

-type open_option() ::
    {layer, binary()}.

-type create_option() ::
    {layer, binary()}
    | {node_name, binary()}.

-if(?DOCATTRS).
-doc """
A partition is a directory that acts as its own independent root, with its own
node-prefix space and HCA allocator. Key allocation for everything underneath a
partition is managed by the partition itself rather than by any ancestor root,
giving it a completely separate key namespace.

Because a partition is a root and not a leaf, `get_subspace/1` raises an error
on a partition — data is stored in ordinary directories beneath it.

The absolute root (returned by `root/0`) is also represented as a partition.
""".
-endif.
-type partition() :: #{
    id := binary(),
    node_prefix := binary(),
    content_prefix := binary(),
    allocator := term(),
    allow_manual_names := boolean(),
    name => binary(),
    root => t(),
    path => [path_item()],
    is_partition => true,
    is_absolute_root => true,
    get_id := fun((t()) -> binary()),
    get_name => fun((t()) -> binary()),
    get_root := fun((t()) -> t()),
    get_root_for_path := fun((t(), path()) -> t()),
    get_partition := fun((t()) -> t()),
    get_node_prefix := fun((t()) -> binary()),
    get_path := fun((t()) -> [path_item()]),
    get_layer := fun((t()) -> binary()),
    get_subspace := fun((t()) -> term())
}.

-if(?DOCATTRS).
-doc """
A directory is a named subdirectory within a root or partition. Its keys are
allocated by the root's HCA allocator and stored under a content prefix derived
from that allocated node name. The `layer` field is an arbitrary binary that
applications use to tag what kind of data lives in the directory (e.g.
`<<"tenant">>`). `get_subspace/1` returns a usable subspace for reading and
writing key-value data.
""".
-endif.
-type directory() :: #{
    id := binary(),
    name := binary(),
    root := t(),
    path := [path_item()],
    layer := binary(),
    get_id := fun((t()) -> binary()),
    get_name := fun((t()) -> binary()),
    get_root := fun((t()) -> t()),
    get_root_for_path := fun((t(), path()) -> t()),
    get_partition := fun((t()) -> t()),
    get_node_prefix := fun((t()) -> binary()),
    get_path := fun((t()) -> [path_item()]),
    get_layer := fun((t()) -> binary()),
    get_subspace := fun((t()) -> term())
}.

-if(?DOCATTRS).
-doc "A directory layer node — either a `partition()` (root) or a `directory()` (leaf).".
-endif.
-type t() :: partition() | directory().

-export_type([t/0, path/0, partition/0, directory/0, root_option/0, open_option/0, create_option/0]).

-spec root() -> partition().
root() ->
    init_root([]).

-spec root([root_option()]) -> partition().
root(Options) ->
    init_root(Options).

-spec create_or_open(erlfdb:tx_object(), t(), path()) -> t().
create_or_open(TxObj, Node, Path) ->
    create_or_open(TxObj, Node, Path, <<>>).

-spec create_or_open(erlfdb:tx_object(), t(), path(), binary()) -> t().
create_or_open(TxObj, Node, PathIn, Layer) ->
    {Root, Path} = adj_path(Node, PathIn),
    if
        Path /= [] -> ok;
        true -> ?ERLFDB_ERROR({open_error, cannot_open_root})
    end,
    case create_or_open_int(TxObj, Root, Path, Layer) of
        #{is_absolute_root := true} ->
            ?ERLFDB_ERROR({open_error, cannot_open_root});
        Else ->
            Else
    end.

-spec create(erlfdb:tx_object(), t(), path()) -> t().
create(TxObj, Node, Path) ->
    create(TxObj, Node, Path, []).

-spec create(erlfdb:tx_object(), t(), path(), [create_option()]) -> t().
create(TxObj, Node, PathIn, Options) ->
    {Root, Path} = adj_path(Node, PathIn),
    check_manual_node_name(Root, Options),
    erlfdb:transactional(TxObj, fun(Tx) ->
        Layer = erlfdb_util:get(Options, layer, <<>>),
        NodeName = erlfdb_util:get(Options, node_name, undefined),
        create_int(Tx, Root, Path, Layer, NodeName)
    end).

-spec open(erlfdb:tx_object(), t(), path()) -> t().
open(TxObj, Node, Path) ->
    open(TxObj, Node, Path, []).

-spec open(erlfdb:tx_object(), t(), path(), [open_option()]) -> t().
open(TxObj, Node, PathIn, Options) ->
    {Root, Path} = adj_path(Node, PathIn),
    if
        Path /= [] -> ok;
        true -> ?ERLFDB_ERROR({open_error, cannot_open_root})
    end,
    erlfdb:transactional(TxObj, fun(Tx) ->
        Layer = erlfdb_util:get(Options, layer, <<>>),
        open_int(Tx, Root, Path, Layer)
    end).

-if(?DOCATTRS).
-doc """
Lists the immediate subdirectories of `Node`.
Equivalent to `list(TxObj, Node, {})`.
""".
-endif.
-spec list(erlfdb:tx_object(), t()) -> [{path_item(), t()}].
list(TxObj, Node) ->
    list(TxObj, Node, {}).

-if(?DOCATTRS).
-doc """
Lists the immediate subdirectories of the directory at `Path` under `Node`.

Returns `[{Name, ChildNode}]` where each `Name` is a `path_item()`. In
practice the directory layer always stores names as `{utf8, Binary}` tuples,
so pattern matching on the first element should use that form:

```erlang
Listed = erlfdb_directory:list(Db, Root),
Names = [N || {{utf8, N}, _Node} <- Listed].
```

Raises `{erlfdb_directory, {list_error, missing_path, Path}}` if `Path` does
not exist under `Node`.
""".
-endif.
-spec list(erlfdb:tx_object(), t(), path()) -> [{path_item(), t()}].
list(TxObj, Node, PathIn) ->
    {Root, Path} = adj_path(Node, PathIn),
    erlfdb:transactional(TxObj, fun(Tx) ->
        check_version(Tx, Root, read),
        case find(Tx, Root, Path) of
            not_found ->
                ?ERLFDB_ERROR({list_error, missing_path, Path});
            ListNode ->
                Subdirs = ?ERLFDB_EXTEND(get_id(ListNode), ?SUBDIRS),
                SDLen = size(Subdirs),
                SDStart = <<Subdirs:SDLen/binary, 16#00>>,
                SDEnd = <<Subdirs:SDLen/binary, 16#FF>>,
                SubDirKVs = erlfdb:wait(erlfdb:get_range(Tx, SDStart, SDEnd)),
                lists:map(
                    fun({Key, NodeName}) ->
                        {DName} = ?ERLFDB_EXTRACT(Subdirs, Key),
                        ChildNode = init_node(Tx, ListNode, NodeName, DName),
                        {DName, ChildNode}
                    end,
                    SubDirKVs
                )
        end
    end).

-spec exists(erlfdb:tx_object(), t()) -> boolean().
exists(TxObj, Node) ->
    exists(TxObj, Node, {}).

-spec exists(erlfdb:tx_object(), t(), path()) -> boolean().
exists(TxObj, Node, PathIn) ->
    %Root = get_root(Node),
    Root = get_root_for_path(Node, PathIn),
    {Root, Path} = adj_path(Root, Node, PathIn),
    erlfdb:transactional(TxObj, fun(Tx) ->
        check_version(Tx, Root, read),
        case find(Tx, Root, Path) of
            not_found ->
                false;
            _ChildNode ->
                true
        end
    end).

-spec move(erlfdb:tx_object(), t(), path(), path()) -> t().
move(TxObj, Node, OldPathIn, NewPathIn) ->
    {Root, OldPath} = adj_path(Node, OldPathIn),
    {Root, NewPath} = adj_path(Node, NewPathIn),
    erlfdb:transactional(TxObj, fun(Tx) ->
        check_version(Tx, Root, write),
        check_not_subpath(OldPath, NewPath),

        OldNode = find(Tx, Root, OldPath),
        NewNode = find(Tx, Root, NewPath),

        if
            OldNode /= not_found -> ok;
            true -> ?ERLFDB_ERROR({move_error, missing_source, OldPath})
        end,

        if
            NewNode == not_found -> ok;
            true -> ?ERLFDB_ERROR({move_error, target_exists, NewPath})
        end,

        {NewParentPath, [NewName]} = lists:split(length(NewPath) - 1, NewPath),
        case find(Tx, Root, NewParentPath) of
            not_found ->
                ?ERLFDB_ERROR({move_error, missing_parent_node, NewParentPath});
            NewParentNode ->
                check_same_partition(OldNode, NewParentNode),
                ParentId = get_id(NewParentNode),
                NodeEntryId = ?ERLFDB_PACK(ParentId, {?SUBDIRS, NewName}),
                erlfdb:set(Tx, NodeEntryId, get_name(OldNode)),
                remove_from_parent(Tx, OldNode),
                OldNode#{path := get_path(Root) ++ NewPath}
        end
    end).

-spec move_to(erlfdb:tx_object(), t(), path()) -> t().
move_to(_TxObj, #{is_absolute_root := true}, _NewPath) ->
    ?ERLFDB_ERROR({move_error, root_cannot_be_moved});
move_to(TxObj, Node, NewAbsPathIn) ->
    Root = get_root_for_path(Node, []),
    RootPath = get_path(Root),
    RootPathLen = length(RootPath),
    NewAbsPath = path_init(NewAbsPathIn),
    IsPrefix = lists:prefix(RootPath, NewAbsPath),
    if
        IsPrefix -> ok;
        true -> ?ERLFDB_ERROR({move_error, partition_mismatch, RootPath, NewAbsPath})
    end,
    NodePath = get_path(Node),
    SrcPath = lists:nthtail(RootPathLen, NodePath),
    TgtPath = lists:nthtail(RootPathLen, NewAbsPath),
    move(TxObj, Root, SrcPath, TgtPath).

-spec remove(erlfdb:tx_object(), t()) -> ok.
remove(TxObj, Node) ->
    remove_int(TxObj, Node, {}, false).

-spec remove(erlfdb:tx_object(), t(), path()) -> ok.
remove(TxObj, Node, Path) ->
    remove_int(TxObj, Node, Path, false).

-spec remove_if_exists(erlfdb:tx_object(), t()) -> ok.
remove_if_exists(TxObj, Node) ->
    remove_int(TxObj, Node, {}, true).

-spec remove_if_exists(erlfdb:tx_object(), t(), path()) -> ok.
remove_if_exists(TxObj, Node, Path) ->
    remove_int(TxObj, Node, Path, true).

-spec get_id(t()) -> binary().
get_id(Node) ->
    invoke(Node, get_id, []).

-spec get_name(t()) -> binary().
get_name(Node) ->
    invoke(Node, get_name, []).

-spec get_root(t()) -> t().
get_root(Node) ->
    invoke(Node, get_root, []).

-spec get_root_for_path(t(), path()) -> t().
get_root_for_path(Node, Path) ->
    invoke(Node, get_root_for_path, [Path]).

get_partition(Node) ->
    invoke(Node, get_partition, []).

-spec get_node_prefix(t()) -> binary().
get_node_prefix(Node) ->
    invoke(Node, get_node_prefix, []).

-spec get_path(t()) -> [path_item()].
get_path(Node) ->
    invoke(Node, get_path, []).

-spec get_layer(t()) -> binary().
get_layer(Node) ->
    invoke(Node, get_layer, []).

-spec get_subspace(t()) -> term().
get_subspace(Node) ->
    invoke(Node, get_subspace, []).

-spec subspace(t(), tuple()) -> term().
subspace(Node, Tuple) ->
    erlfdb_subspace:create(get_subspace(Node), Tuple).

-spec key(t()) -> binary().
key(Node) ->
    erlfdb_subspace:key(get_subspace(Node)).

-spec pack(t(), tuple()) -> binary().
pack(Node, Tuple) ->
    erlfdb_subspace:pack(get_subspace(Node), Tuple).

-spec pack_vs(t(), tuple()) -> binary().
pack_vs(Node, Tuple) ->
    erlfdb_subspace:pack_vs(get_subspace(Node), Tuple).

-spec unpack(t(), binary()) -> tuple().
unpack(Node, Key) ->
    erlfdb_subspace:unpack(get_subspace(Node), Key).

-spec range(t()) -> {binary(), binary()}.
range(Node) ->
    range(Node, {}).

-spec range(t(), tuple()) -> {binary(), binary()}.
range(Node, Tuple) ->
    erlfdb_subspace:range(get_subspace(Node), Tuple).

-spec contains(t(), binary()) -> boolean().
contains(Node, Key) ->
    erlfdb_subspace:contains(get_subspace(Node), Key).

-spec debug_nodes(erlfdb:tx_object(), t()) -> ok | nil.
debug_nodes(TxObj, _Node) ->
    erlfdb:fold_range(
        TxObj,
        <<16#02>>,
        <<16#FF>>,
        fun({K, V}, _Acc) ->
            io:format(standard_error, "~s => ~s~n", [
                erlfdb_util:repr(K),
                erlfdb_util:repr(V)
            ])
        end,
        nil
    ).

-spec invoke(t() | not_found, atom(), [term()]) -> term().
invoke(not_found, _, _) ->
    erlang:error(broken);
invoke(Node, FunName, Args) ->
    case Node of
        #{FunName := Fun} ->
            erlang:apply(Fun, [Node | Args]);
        #{} ->
            ?ERLFDB_ERROR({op_not_supported, FunName, Node})
    end.

-spec init_root([root_option()]) -> partition().
init_root(Options) ->
    DefNodePref = ?DEFAULT_NODE_PREFIX,
    NodePrefix = erlfdb_util:get(Options, node_prefix, DefNodePref),
    RootNodeId = ?ERLFDB_EXTEND(NodePrefix, NodePrefix),
    ContentPrefix = erlfdb_util:get(Options, content_prefix, <<>>),
    AllowManual = erlfdb_util:get(Options, allow_manual_names, false),
    Allocator = erlfdb_hca:create(?ERLFDB_EXTEND(RootNodeId, <<"hca">>)),
    #{
        id => ?ERLFDB_EXTEND(NodePrefix, NodePrefix),
        node_prefix => NodePrefix,
        content_prefix => ContentPrefix,
        allocator => Allocator,
        allow_manual_names => AllowManual,
        is_absolute_root => true,

        get_id => fun(Self) -> maps:get(id, Self) end,
        get_root => fun(Self) -> Self end,
        get_root_for_path => fun(Self, _Path) -> Self end,
        get_partition => fun(Self) -> Self end,
        get_node_prefix => fun(Self) -> maps:get(node_prefix, Self) end,
        get_path => fun(_Self) -> [] end,
        get_layer => fun(_Self) -> <<>> end,
        get_subspace => fun(_Self) ->
            ?ERLFDB_ERROR({subspace_error, subspace_unsupported_for_root})
        end
    }.

-spec init_node(erlfdb:transaction(), t(), binary(), path_item()) -> t().
init_node(Tx, Node, NodeName, PathName) ->
    NodePrefix = get_node_prefix(Node),
    NodeLayerId = ?ERLFDB_PACK(NodePrefix, {NodeName, <<"layer">>}),
    Layer =
        case erlfdb:wait(erlfdb:get(Tx, NodeLayerId)) of
            not_found ->
                ?ERLFDB_ERROR({internal_error, missing_node_layer, NodeLayerId});
            LName ->
                LName
        end,
    case Layer of
        <<"partition">> ->
            init_partition(Node, NodeName, PathName);
        _ ->
            init_directory(Node, NodeName, PathName, Layer)
    end.

-spec init_partition(t(), binary(), path()) -> partition().
init_partition(ParentNode, NodeName, PathName) ->
    NodeNameLen = size(NodeName),
    NodePrefix = <<NodeName:NodeNameLen/binary, 16#FE>>,
    RootNodeId = ?ERLFDB_EXTEND(NodePrefix, NodePrefix),
    Allocator = erlfdb_hca:create(?ERLFDB_EXTEND(RootNodeId, <<"hca">>)),
    #{
        id => RootNodeId,
        name => NodeName,
        root => get_root(ParentNode),
        node_prefix => NodePrefix,
        content_prefix => NodeName,
        allocator => Allocator,
        allow_manual_names => false,
        path => path_append(get_path(ParentNode), PathName),
        is_partition => true,

        get_id => fun(Self) -> maps:get(id, Self) end,
        get_name => fun(Self) -> maps:get(name, Self) end,
        get_root => fun(Self) -> Self end,
        get_root_for_path => fun(Self, PathIn) ->
            case PathIn of
                {} -> maps:get(root, Self);
                [] -> maps:get(root, Self);
                _ -> Self
            end
        end,
        get_partition => fun(Self) -> maps:get(root, Self) end,
        get_node_prefix => fun(Self) -> maps:get(node_prefix, Self) end,
        get_path => fun(Self) -> maps:get(path, Self) end,
        get_layer => fun(_Self) -> <<"partition">> end,
        get_subspace => fun(_Self) ->
            ?ERLFDB_ERROR({subspace_error, subspace_unsupported_for_partition})
        end
    }.

-spec init_directory(t(), binary(), binary(), path()) -> directory().
init_directory(ParentNode, NodeName, PathName, Layer) ->
    NodePrefix = get_node_prefix(ParentNode),
    ParentPath = get_path(ParentNode),
    #{
        id => ?ERLFDB_EXTEND(NodePrefix, NodeName),
        name => NodeName,
        root => get_root(ParentNode),
        path => path_append(ParentPath, PathName),
        layer => Layer,

        get_id => fun(Self) -> maps:get(id, Self) end,
        get_name => fun(Self) -> maps:get(name, Self) end,
        get_root => fun(Self) -> maps:get(root, Self) end,
        get_root_for_path => fun(Self, Path) ->
            NewPath = maps:get(path, Self) ++ path_init(Path),
            get_root_for_path(maps:get(root, Self), NewPath)
        end,
        get_partition => fun(Self) -> maps:get(root, Self) end,
        get_node_prefix => fun(Self) ->
            Root = maps:get(root, Self),
            get_node_prefix(Root)
        end,
        get_path => fun(Self) -> maps:get(path, Self) end,
        get_layer => fun(Self) -> maps:get(layer, Self) end,
        get_subspace => fun(Self) ->
            erlfdb_subspace:create({}, maps:get(name, Self))
        end
    }.

-spec find(erlfdb:transaction(), t(), [path_item()]) -> t() | not_found.
find(_Tx, Node, []) ->
    Node;
find(Tx, Node, [PathName | RestPath]) ->
    NodeEntryId = ?ERLFDB_PACK(get_id(Node), {?SUBDIRS, PathName}),
    case erlfdb:wait(erlfdb:get(Tx, NodeEntryId)) of
        not_found ->
            not_found;
        ChildNodeName ->
            ChildNode = init_node(Tx, Node, ChildNodeName, PathName),
            find(Tx, ChildNode, RestPath)
    end.

-spec find_deepest(erlfdb:transaction(), t(), [path_item()]) -> t().
find_deepest(_Tx, Node, []) ->
    Node;
find_deepest(Tx, Node, [PathName | RestPath]) ->
    NodeEntryId = ?ERLFDB_PACK(get_id(Node), {?SUBDIRS, PathName}),
    case erlfdb:wait(erlfdb:get(Tx, NodeEntryId)) of
        not_found ->
            Node;
        ChildNodeName ->
            ChildNode = init_node(Tx, Node, ChildNodeName, PathName),
            find_deepest(Tx, ChildNode, RestPath)
    end.

-spec create_or_open_int(erlfdb:tx_object(), t(), [path_item()], binary()) -> t().
create_or_open_int(_TxObj, Node, [], LayerIn) ->
    Layer =
        case LayerIn of
            <<>> -> <<>>;
            null -> <<>>;
            undefined -> <<>>;
            Else when is_binary(Else) -> Else
        end,
    NodeLayer = get_layer(Node),
    if
        Layer == <<>> orelse Layer == NodeLayer -> ok;
        true -> ?ERLFDB_ERROR({open_error, layer_mismatch, Layer, NodeLayer})
    end,
    Node;
create_or_open_int(TxObj, Node, PathIn, Layer) ->
    {Root, Path} = adj_path(Node, PathIn),
    erlfdb:transactional(TxObj, fun(Tx) ->
        {ParentPath, [PathName]} = lists:split(length(Path) - 1, Path),

        Parent = lists:foldl(
            fun(Name, CurrNode) ->
                try
                    open_int(Tx, CurrNode, Name, <<>>)
                catch
                    error:{?MODULE, {open_error, path_missing, _}} ->
                        create_int(Tx, CurrNode, Name, <<>>, undefined)
                end
            end,
            Root,
            ParentPath
        ),

        try
            open_int(Tx, Parent, PathName, Layer)
        catch
            error:{?MODULE, {open_error, path_missing, _}} ->
                create_int(Tx, Parent, PathName, Layer, undefined)
        end
    end).

-spec create_int(erlfdb:transaction(), t(), path(), binary(), binary() | undefined) -> t().
create_int(Tx, Node, PathIn, Layer, NodeNameIn) ->
    Path = path_init(PathIn),
    try
        open_int(Tx, Node, Path, <<>>),
        ?ERLFDB_ERROR({create_error, path_exists, Path})
    catch
        error:{?MODULE, {open_error, path_missing, _}} ->
            Deepest = find_deepest(Tx, Node, Path),
            NodeName = create_node_name(Tx, Deepest, NodeNameIn),
            {ParentPath, [PathName]} = lists:split(length(Path) - 1, Path),
            Parent = create_or_open_int(Tx, Node, ParentPath, <<>>),
            check_version(Tx, Parent, write),
            create_node(Tx, Parent, PathName, NodeName, Layer),
            R = find(Tx, Parent, [PathName]),
            if
                R /= not_found -> R;
                true -> erlang:error(broken)
            end
    end.

-spec create_node(erlfdb:transaction(), t(), path_item(), binary(), binary() | undefined) -> ok.
create_node(Tx, Parent, PathName, NodeName, LayerIn) ->
    NodeEntryId = ?ERLFDB_PACK(get_id(Parent), {?SUBDIRS, PathName}),
    erlfdb:set(Tx, NodeEntryId, NodeName),

    NodePrefix = get_node_prefix(Parent),
    NodeLayerId = ?ERLFDB_PACK(NodePrefix, {NodeName, <<"layer">>}),
    Layer =
        if
            LayerIn == undefined -> <<>>;
            true -> LayerIn
        end,
    erlfdb:set(Tx, NodeLayerId, Layer).

-spec open_int(erlfdb:transaction(), t(), path(), binary()) -> t().
open_int(Tx, Node, PathIn, Layer) ->
    check_version(Tx, Node, read),
    Path = path_init(PathIn),
    case find(Tx, Node, Path) of
        not_found ->
            ?ERLFDB_ERROR({open_error, path_missing, Path});
        #{is_absolute_root := true} ->
            ?ERLFDB_ERROR({open_error, cannot_open_root});
        Opened ->
            NodeLayer = get_layer(Opened),
            if
                Layer == <<>> orelse Layer == NodeLayer -> ok;
                true -> ?ERLFDB_ERROR({open_error, layer_mismatch, Layer, NodeLayer})
            end,
            Opened
    end.

-spec remove_int(erlfdb:tx_object(), t(), path(), boolean()) -> ok.
remove_int(TxObj, Node, PathIn, IgnoreMissing) ->
    Root = get_root_for_path(Node, PathIn),
    {Root, Path} = adj_path(Root, Node, PathIn),
    erlfdb:transactional(TxObj, fun(Tx) ->
        check_version(Tx, Root, write),
        case find(Tx, Root, Path) of
            not_found when IgnoreMissing ->
                ok;
            not_found ->
                ?ERLFDB_ERROR({remove_error, path_missing, Path});
            #{is_absolute_root := true} ->
                ?ERLFDB_ERROR({remove_error, cannot_remove_root});
            ToRem ->
                remove_recursive(Tx, ToRem),
                remove_from_parent(Tx, ToRem)
        end
    end).

-spec remove_recursive(erlfdb:transaction(), t()) -> ok.
remove_recursive(Tx, Node) ->
    % Remove all subdirectories
    lists:foreach(
        fun({_DirName, ChildNode}) ->
            remove_recursive(Tx, ChildNode)
        end,
        list(Tx, Node)
    ),

    % Delete all content for the node.
    ContentSS = erlfdb_subspace:create({}, get_name(Node)),
    {ContentStart, ContentEnd} = erlfdb_subspace:range(ContentSS),
    erlfdb:clear_range(Tx, ContentStart, ContentEnd),

    % Delete this node from the tree hierarchy
    NodeSubspace = erlfdb_subspace:create({}, get_id(Node)),
    {NodeStart, NodeEnd} = erlfdb_subspace:range(NodeSubspace),
    erlfdb:clear_range(Tx, NodeStart, NodeEnd).

-spec remove_from_parent(erlfdb:transaction(), t()) -> ok.
remove_from_parent(Tx, Node) ->
    {Root, Path} = adj_path(get_root_for_path(Node, []), Node, []),
    {ParentPath, [PathName]} = lists:split(length(Path) - 1, Path),
    Parent = find(Tx, Root, ParentPath),

    NodeEntryId = ?ERLFDB_PACK(get_id(Parent), {?SUBDIRS, PathName}),
    erlfdb:clear(Tx, NodeEntryId).

-spec check_manual_node_name(partition(), [create_option()]) -> ok.
check_manual_node_name(Root, Options) ->
    AllowManual = maps:get(allow_manual_names, Root),
    IsManual = lists:keyfind(node_name, 1, Options) /= false,
    if
        not (IsManual and not AllowManual) -> ok;
        true -> ?ERLFDB_ERROR({create_error, manual_node_names_prohibited})
    end.

-spec create_node_name(erlfdb:transaction(), t(), binary() | null | undefined) -> binary().
create_node_name(Tx, Parent, NameIn) ->
    #{
        content_prefix := ContentPrefix,
        allow_manual_names := AllowManual,
        allocator := Allocator
    } = get_root(Parent),
    Name =
        case NameIn of
            null -> undefined;
            undefined -> undefined;
            _ when is_binary(NameIn) -> NameIn
        end,
    case Name of
        _ when Name == undefined ->
            BaseId = erlfdb_hca:allocate(Allocator, Tx),
            CPLen = size(ContentPrefix),
            NewName = <<ContentPrefix:CPLen/binary, BaseId/binary>>,

            KeysExist = erlfdb:wait(erlfdb:get_range_startswith(Tx, NewName, [{limit, 1}])),
            if
                KeysExist == [] ->
                    ok;
                true ->
                    ?ERLFDB_ERROR({
                        create_error,
                        keys_exist_for_allocated_name,
                        NewName
                    })
            end,

            IsFree = is_prefix_free(erlfdb:snapshot(Tx), Parent, NewName),
            if
                IsFree ->
                    ok;
                true ->
                    ?ERLFDB_ERROR({
                        create_error,
                        manual_names_conflict_with_allocated_name,
                        NewName
                    })
            end,

            NewName;
        _ when AllowManual andalso is_binary(Name) ->
            case is_prefix_free(Tx, Parent, NameIn) of
                true ->
                    ok;
                false ->
                    ?ERLFDB_ERROR({create_error, node_name_in_use, NameIn})
            end,
            NameIn;
        _ ->
            ?ERLFDB_ERROR({create_error, manual_node_names_prohibited})
    end.

-spec is_prefix_free(erlfdb:transaction() | erlfdb:snapshot(), t(), binary()) -> boolean().
is_prefix_free(Tx, Parent, NodeName) ->
    % We have to make sure that NodeName does not interact with
    % anything that currently exists in the tree. This means that
    % it must not be a prefix of any existing node id and also
    % that no existing node id is a prefix of this NodeName.
    %
    % A motivating example for why is that deletion of nodes
    % in the tree would end up deleting unrelated portions
    % of the tree when node ids overlapped. There would also
    % be other badness if keys overlapped with the layer
    % or ?SUBDIRS spaces.

    try
        % An empty name would obviously be kind of bonkers.
        if
            NodeName /= <<>> -> ok;
            true -> throw(false)
        end,

        Root = get_root(Parent),
        RootId = get_id(Root),
        NodePrefix = get_node_prefix(Root),
        NPLen = size(NodePrefix),

        % First check that the special case of the root node
        case bin_startswith(NodeName, RootId) of
            true -> throw(false);
            false -> ok
        end,

        % Check if any node id is a prefix of NodeName
        Start1 = <<NodePrefix:NPLen/binary, 16#00>>,
        End1 = ?ERLFDB_PACK(NodePrefix, {NodeName, null}),
        Opts1 = [{reverse, true}, {limit, 1}, {streaming_mode, exact}],
        Subspace = erlfdb_subspace:create({}, get_node_prefix(Parent)),
        erlfdb:fold_range(
            Tx,
            Start1,
            End1,
            fun({Key, _} = _E, _) ->
                KeyNodeId = element(1, erlfdb_subspace:unpack(Subspace, Key)),
                case bin_startswith(NodeName, KeyNodeId) of
                    true -> throw(false);
                    false -> ok
                end
            end,
            nil,
            Opts1
        ),

        % Check if NodeName is a prefix of any existing key
        Start2 = ?ERLFDB_EXTEND(NodePrefix, NodeName),
        End2 = ?ERLFDB_EXTEND(NodePrefix, erlfdb_key:strinc(NodeName)),
        Opts2 = [{limit, 1}, {streaming_mode, exact}],
        case erlfdb:wait(erlfdb:get_range(Tx, Start2, End2, Opts2)) of
            [_E | _] -> throw(false);
            [] -> ok
        end,

        true
    catch
        throw:false ->
            false
    end.

-spec bin_startswith(binary(), binary()) -> boolean().
bin_startswith(Subject, Prefix) ->
    PrefixLen = size(Prefix),
    case Subject of
        <<Prefix:PrefixLen/binary, _/binary>> -> true;
        _ -> false
    end.

-spec check_version(erlfdb:transaction(), t(), read | write) -> ok.
check_version(Tx, Node, PermLevel) ->
    Root = get_root(Node),
    VsnKey = ?ERLFDB_EXTEND(get_id(Root), <<"version">>),
    {LV1, LV2, _LV3} = ?LAYER_VERSION,
    {Major, Minor, Patch} =
        case erlfdb:wait(erlfdb:get(Tx, VsnKey)) of
            not_found when PermLevel == write ->
                initialize_directory(Tx, VsnKey);
            not_found ->
                ?LAYER_VERSION;
            VsnBin ->
                <<
                    V1:32/little-unsigned,
                    V2:32/little-unsigned,
                    V3:32/little-unsigned
                >> = VsnBin,
                {V1, V2, V3}
        end,

    Path = get_path(Node),

    if
        Major =< LV1 -> ok;
        true -> ?ERLFDB_ERROR({version_error, unreadable, Path, {Major, Minor, Patch}})
    end,

    if
        not (Minor > LV2 andalso PermLevel /= read) -> ok;
        true -> ?ERLFDB_ERROR({version_error, unwritable, Path, {Major, Minor, Patch}})
    end.

-spec initialize_directory(erlfdb:transaction(), binary()) ->
    {non_neg_integer(), non_neg_integer(), non_neg_integer()}.
initialize_directory(Tx, VsnKey) ->
    {V1, V2, V3} = ?LAYER_VERSION,
    Packed = <<
        V1:32/little-unsigned,
        V2:32/little-unsigned,
        V3:32/little-unsigned
    >>,
    erlfdb:set(Tx, VsnKey, Packed),
    ?LAYER_VERSION.

-spec check_same_partition(t(), t()) -> ok.
check_same_partition(OldNode, NewParentNode) ->
    OldRoot = get_partition(OldNode),
    NewRoot = get_root(NewParentNode),
    if
        NewRoot == OldRoot -> ok;
        true -> ?ERLFDB_ERROR({move_error, partition_mismatch, OldRoot, NewRoot})
    end.

-if(?DOCATTRS).
-doc """
Resolves `Node` and `PathIn` to a canonical `{Root, Path}` pair, where `Root` is
the partition that actually owns `Node` and `Path` is the fully-normalized path
of the target relative to that `Root`.

`Path` is independent of how `PathIn` was expressed (binary, `{utf8, _}`, list,
or tuple) and of which descendant of `Root` was supplied as `Node`: it is always
the absolute path within the owning partition. This makes `{get_node_prefix(Root),
Path}` a collision-free identity for a directory.
""".
-endif.
-spec adj_path(t(), path()) -> {t(), [path_item()]}.
adj_path(Node, PathIn) ->
    adj_path(get_root(Node), Node, PathIn).

-spec adj_path(t(), t(), path()) -> {t(), [path_item()]}.
adj_path(Root, Node, PathIn) ->
    RootPathLen = length(get_path(Root)),
    NodePath = get_path(Node),
    NodeRelPath = lists:nthtail(RootPathLen, NodePath),
    Path = NodeRelPath ++ path_init(PathIn),
    {Root, Path}.

-spec path_init(path()) -> [path_item()].
path_init(<<_/binary>> = Bin) ->
    check_utf8(0, Bin),
    [{utf8, Bin}];
path_init({utf8, <<_/binary>> = Bin} = Path) ->
    check_utf8(0, Bin),
    [Path];
path_init(Path) when is_list(Path) ->
    lists:flatmap(
        fun(Part) ->
            path_init(Part)
        end,
        Path
    );
path_init(Path) when is_tuple(Path) ->
    path_init(tuple_to_list(Path));
path_init(Else) ->
    ?ERLFDB_ERROR({path_error, invalid_path_component, Else}).

-spec check_utf8(non_neg_integer(), binary()) -> true.
check_utf8(Offset, Binary) ->
    case Binary of
        <<_:Offset/binary>> ->
            true;
        <<_:Offset/binary, _/utf8, Rest/binary>> ->
            % Recalculating offset as a subtraction here is
            % slightly odd but this is to avoid having to
            % re-encode the utf8 code point and adding the
            % size of that new binary.
            check_utf8(size(Binary) - size(Rest), Binary);
        <<_:Offset/binary, _/binary>> ->
            ?ERLFDB_ERROR({path_error, invalid_utf8, Binary})
    end.

-spec path_append([path_item()], path()) -> [path_item()].
path_append(Path, Part) ->
    Path ++ path_init(Part).

-spec check_not_subpath([path_item()], [path_item()]) -> ok.
check_not_subpath(OldPath, NewPath) ->
    case lists:prefix(OldPath, NewPath) of
        true ->
            ?ERLFDB_ERROR({
                move_error,
                target_is_subdirectory,
                OldPath,
                NewPath
            });
        false ->
            ok
    end.
