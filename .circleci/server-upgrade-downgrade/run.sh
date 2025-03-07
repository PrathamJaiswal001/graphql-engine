#! /usr/bin/env bash

# This script tests the migration path both *from* the latest release *to* the
# version in this PR, and the downgrade path *back* to that release. It makes
# use of the functionality already excercised in our integration tests, and
# does something like:
#
#    for a subset of tests in tests that are okay to run here:
#       run setup and test using OLD_VERSION, don't run teardown
#       start THIS_VERSION, running migration code on anything set up above
#         run the same pytests, don't run setup or teardown
#       start OLD_VERSION again, running down migrations
#         run the same pytests, don't run setup
#
# This makes use of BUILDKITE_PARALLEL_JOB_COUNT and BUILDKITE_PARALLEL_JOB if
# present to determine which subset of tests to run as part of a parallelized
# test.

set -euo pipefail

# # keep track of the last executed command
# trap 'last_command=$current_command; current_command=$BASH_COMMAND' DEBUG
# # echo an error message before exiting
# trap 'echo "\"${last_command}\" command filed with exit code $?."' EXIT

cd "${BASH_SOURCE[0]%/*}"
ROOT="${PWD}"
cd - >/dev/null

download_with_etag_check() {
	URL="$1"
	FILE="$2"
	ETAG="$(curl -I $URL | grep etag: | awk '{print $2}' | sed 's/\r$//')"
	set -x
	if ! ([ -f "$FILE" ] && [ "$(cat "$FILE.etag" 2>/dev/null)" == "$ETAG" ]); then
		curl -Lo "$FILE" "$URL"
		chmod +x "$FILE"
		echo -e -n "$ETAG" >"$FILE.etag"
	fi
	set +x
}

fail_if_port_busy() {
	local PORT=$1
	if nc -z localhost $PORT; then
		echo "Port $PORT is busy. Exiting"
		exit 1
	fi
}

# wait_for_port PORT [PID] [LOG_FILE]
wait_for_port() {
	local PORT=$1
	local PIDMSG=""
	local PID=${2:-}
	if [ -n "$PID" ]; then
		PIDMSG=", PID ($PID)"
	fi
	echo "waiting for ${PORT}${PIDMSG}"
	for _i in $(seq 1 60); do
		nc -z localhost $PORT && echo "port $PORT is ready" && return
		echo -n .
		sleep 1
		if [ -n "$PID" ] && ! ps $PID >/dev/null; then
			echo "Process $PID has exited"
			if [ -n "${3:-}" ]; then
				cat $3
			fi
			exit 1
		fi
	done
	echo "Failed waiting for $PORT" && exit 1
}

wait_for_postgres() {
        for _i in $(seq 1 60); do
                psql "$1" -c '' >/dev/null 2>&1 && \
                        echo "postgres is ready at $1" && \
                        return
                echo -n .
                sleep 1
        done
        echo "failed waiting for postgres at $1" && return 1
}

log() { echo $'\e[1;33m'"--> $*"$'\e[0m'; }

: ${HASURA_GRAPHQL_SERVER_PORT:=8080}
: ${API_SERVER_PORT:=3000}
: ${HASURA_PROJECT_DIR:=$ROOT/hasura}
: ${API_SERVER_DIR:=$ROOT/api-server}
: ${SERVER_OUTPUT_DIR:=/build/_server_output}
: ${SERVER_TEST_OUTPUT_DIR:=/build/_server_test_output}
: ${SERVER_BINARY:=/build/_server_output/graphql-engine}
: ${LATEST_SERVER_BINARY:=/bin/graphql-engine-latest}
: ${HASURA_GRAPHQL_STRINGIFY_NUMERIC_TYPES:=true}

LATEST_SERVER_LOG=$SERVER_TEST_OUTPUT_DIR/upgrade-test-latest-release-server.log
CURRENT_SERVER_LOG=$SERVER_TEST_OUTPUT_DIR/upgrade-test-current-server.log

# export them so that GraphQL Engine can use it
export HASURA_GRAPHQL_STRINGIFY_NUMERIC_TYPES="$HASURA_GRAPHQL_STRINGIFY_NUMERIC_TYPES"
# Required for testing caching
export GHCRTS='-N1'
# Required for event trigger tests
export EVENT_WEBHOOK_HANDLER="http://127.0.0.1:5592"
export EVENT_WEBHOOK_HEADER="MyEnvValue"
export REMOTE_SCHEMAS_WEBHOOK_DOMAIN="http://127.0.0.1:5000"

# graphql-engine will be run on this port
fail_if_port_busy ${HASURA_GRAPHQL_SERVER_PORT}

# Remote graphql server of pytests run on this port
fail_if_port_busy 5000

log "setting up directories"
mkdir -p $SERVER_OUTPUT_DIR
mkdir -p $SERVER_TEST_OUTPUT_DIR
touch $LATEST_SERVER_LOG
touch $CURRENT_SERVER_LOG

# download latest graphql engine release
log "downloading latest release of graphql engine"
download_with_etag_check 'https://graphql-engine-cdn.hasura.io/server/latest/linux-amd64' "$LATEST_SERVER_BINARY"

cur_server_version() {
	echo "$(curl http://localhost:${HASURA_GRAPHQL_SERVER_PORT}/v1/version -q 2>/dev/null)"
}

log "Run pytests with server upgrade"

PYTEST_DIR="server/tests-py"

WORKTREE_DIR="$(mktemp -d)"
RELEASE_VERSION="$($LATEST_SERVER_BINARY version | cut -d':' -f2 | awk '{print $1}')"
rm_worktree() {
	rm -rf "$WORKTREE_DIR"
}
trap rm_worktree ERR

make_latest_release_worktree() {
	git worktree add --detach "$WORKTREE_DIR" "$RELEASE_VERSION"
}

cleanup_hasura_metadata_if_present() {
	set -x
	psql "$HASURA_GRAPHQL_DATABASE_URL" -c 'drop schema if exists hdb_catalog cascade;
               drop schema if exists hdb_views cascade' >/dev/null 2>/dev/null
	set +x
}

get_tables_of_interest() {
	psql $HASURA_GRAPHQL_DATABASE_URL -P pager=off -c "
select table_schema as schema, table_name as name
from information_schema.tables
where table_schema not in ('hdb_catalog','hdb_views', 'pg_catalog', 'information_schema','topology', 'tiger')
  and (table_schema <> 'public'
         or table_name not in ('geography_columns','geometry_columns','spatial_ref_sys','raster_columns','raster_overviews')
      );
"
}

get_current_catalog_version() {
	psql $HASURA_GRAPHQL_DATABASE_URL -P pager=off -c "SELECT version FROM hdb_catalog.hdb_version"
}

# Return the list of tests over which we will perform a
# test-upgrade-test-downgrade-test sequence in run_server_upgrade_pytest().
#
# See pytest_report_collectionfinish() for the logic that determines what is an
# "upgrade test", namely presence of particular markers.
get_server_upgrade_tests() {
	cd $PYTEST_DIR
	tmpfile="$(mktemp --dry-run)"
	set -x
	# NOTE: any tests deselected in run_server_upgrade_pytest need to be filtered out here too
	#
	# FIX ME: Deselecting some introspection tests and event trigger tests from the previous test suite
	# which throw errors on the latest build. Even when the output of the current build is more accurate.
	# Remove these deselects after the next stable release
	#
	# NOTE: test_events.py involves presistent state and probably isn't
	#       feasible to run here
	# FIXME: re-enable test_graphql_queries.py::TestGraphQLQueryFunctions
	#        (fixing "already exists" error) if possible
	#
	# FIXME: add back `test_limit_orderby_column_query` after next release
	python3 -m pytest -q --collect-only --collect-upgrade-tests-to-file "$tmpfile" \
		-m 'allow_server_upgrade_test and not skip_server_upgrade_test' \
		--deselect test_schema_stitching.py::TestRemoteSchemaBasic::test_introspection \
		--deselect test_schema_stitching.py::TestAddRemoteSchemaCompareRootQueryFields::test_schema_check_arg_default_values_and_field_and_arg_types \
		--deselect test_graphql_mutations.py::TestGraphqlInsertPermission::test_user_with_no_backend_privilege \
		--deselect test_graphql_mutations.py::TestGraphqlInsertPermission::test_backend_user_no_admin_secret_fail \
		--deselect test_graphql_mutations.py::TestGraphqlMutationCustomSchema::test_update_article \
		--deselect test_graphql_queries.py::TestGraphQLQueryEnums::test_introspect_user_role \
		--deselect test_schema_stitching.py::TestRemoteSchemaQueriesOverWebsocket::test_remote_query_error \
		--deselect test_events.py::TestCreateAndDelete::test_create_reset \
		--deselect test_events.py::TestUpdateEvtQuery::test_update_basic \
		--deselect test_schema_stitching.py::TestAddRemoteSchemaTbls::test_add_schema \
		--deselect test_schema_stitching.py::TestAddRemoteSchemaTbls::test_add_conflicting_table \
		--deselect test_events.py \
		--deselect test_graphql_queries.py::TestGraphQLQueryFunctions \
		--deselect test_graphql_queries.py::TestGraphQLExplainCommon::test_limit_orderby_relationship_query \
		--deselect test_graphql_queries.py::TestGraphQLExplainCommon::test_limit_offset_orderby_relationship_query \
		--deselect test_graphql_queries.py::TestGraphQLExplainPostgresMSSQLMySQL::test_limit_orderby_column_query \
		--deselect test_graphql_queries.py::TestGraphQLQueryBoolExpBasicPostgres::test_select_cast_test_where_cast_string \
		--deselect test_graphql_queries.py::TestGraphQLExplainPostgresMSSQLMySQL::test_simple_query \
		--deselect test_graphql_queries.py::TestGraphQLExplainPostgresMSSQLMySQL::test_permissions_query \
		--deselect test_graphql_queries.py::TestGraphQLExplainPostgresMSSQLMySQL::test_limit_query \
		--deselect test_graphql_queries.py::TestGraphQLExplainPostgresMSSQLMySQL::test_orderby_array_relationship_query \
		--deselect test_graphql_queries.py::TestGraphQLExplainPostgresMSSQLMySQL::test_documented_query \
		--deselect test_graphql_queries.py::TestGraphQLExplainPostgresMSSQLMySQL::test_documented_subscription \
		  1>/dev/null 2>/dev/null
	set +x
	# Choose the subset of jobs to run based on possible parallelism in this buildkite job
	# NOTE: BUILDKITE_PARALLEL_JOB starts from 0:
	cat "$tmpfile" | sort |\
	    awk -v C=${BUILDKITE_PARALLEL_JOB_COUNT:-1} -v J=${BUILDKITE_PARALLEL_JOB:-0} 'NR % C == J'
	cd - >/dev/null
	rm "$tmpfile"
}

# The test-upgrade-test-downgrade-test sequence, run for each of many sets of
# tests passed as the argument.
run_server_upgrade_pytest() {
	HGE_PID=""
	cleanup_hge() {
		kill $HGE_PID || true
		wait $HGE_PID || true
		# cleanup_hasura_metadata_if_present
		rm_worktree
	}
	trap cleanup_hge ERR
	local HGE_URL="http://localhost:${HASURA_GRAPHQL_SERVER_PORT}"
	local tests_to_run="$1"

	[ -n "$tests_to_run" ] || (echo "Got no test as input" && false)

	run_pytest() {
		cd $PYTEST_DIR
		set -x

		# With --avoid-error-message-checks, we are only going to throw warnings if the error message has changed between releases
		pytest --hge-urls "${HGE_URL}" --pg-urls "$HASURA_GRAPHQL_DATABASE_URL" \
			--avoid-error-message-checks "$@" \
			-m 'allow_server_upgrade_test and not skip_server_upgrade_test' \
			--deselect test_graphql_mutations.py::TestGraphqlInsertPermission::test_user_with_no_backend_privilege \
			--deselect test_graphql_mutations.py::TestGraphqlMutationCustomSchema::test_update_article \
			--deselect test_graphql_queries.py::TestGraphQLQueryEnums::test_introspect_user_role \
			--deselect test_graphql_queries.py::TestGraphQLExplainCommon::test_limit_orderby_relationship_query \
			--deselect test_graphql_queries.py::TestGraphQLExplainCommon::test_limit_offset_orderby_relationship_query \
		    --deselect test_graphql_queries.py::TestGraphQLExplainPostgresMSSQLMySQL::test_limit_orderby_column_query \
			--deselect test_graphql_queries.py::TestGraphQLQueryBoolExpBasicPostgres::test_select_cast_test_where_cast_string \
			--deselect test_graphql_queries.py::TestGraphQLExplainPostgresMSSQLMySQL::test_simple_query \
			--deselect test_graphql_queries.py::TestGraphQLExplainPostgresMSSQLMySQL::test_permissions_query \
			--deselect test_graphql_queries.py::TestGraphQLExplainPostgresMSSQLMySQL::test_limit_query \
			--deselect test_graphql_queries.py::TestGraphQLExplainPostgresMSSQLMySQL::test_orderby_array_relationship_query \
			--deselect test_graphql_queries.py::TestGraphQLExplainPostgresMSSQLMySQL::test_documented_query \
			--deselect test_graphql_queries.py::TestGraphQLExplainPostgresMSSQLMySQL::test_documented_subscription \
			-v $tests_to_run
		set +x
		cd -
	}

	############## Tests for latest release GraphQL engine #########################

	# Start the old (latest release) GraphQL Engine
	log "starting latest graphql engine release"
	$LATEST_SERVER_BINARY serve >$LATEST_SERVER_LOG 2>&1 &
	HGE_PID=$!

	# Wait for server start
	wait_for_port $HASURA_GRAPHQL_SERVER_PORT $HGE_PID $LATEST_SERVER_LOG

	log "Catalog version for $(cur_server_version)"
	get_current_catalog_version

	log "Run pytest for latest graphql-engine release $(cur_server_version) while skipping schema teardown"
	run_pytest --skip-schema-teardown

	log "kill the api server $(cur_server_version)"
	kill $HGE_PID || true
	wait $HGE_PID || true

	log "the tables of interest in the database are: "
	get_tables_of_interest

	############## Tests for the current build GraphQL engine #########################

	if [[ "$1" =~ "test_schema_stitching" ]]; then
		# In this case, Hasura metadata will have GraphQL servers defined as remote.
		# We need to have remote GraphQL server running for the graphql-engine to avoid
		# inconsistent metadata error
		python3 server/tests-py/graphql_server.py &
		REMOTE_GQL_PID=$!
		wait_for_port 5000
	fi

	log "start the current build"
	set -x
	rm -f graphql-engine.tix
	$SERVER_BINARY serve >$CURRENT_SERVER_LOG 2>&1 &
	HGE_PID=$!
	set +x

	# Wait for server start
	wait_for_port $HASURA_GRAPHQL_SERVER_PORT $HGE_PID $CURRENT_SERVER_LOG

	log "Catalog version for $(cur_server_version)"
	get_current_catalog_version

	if [[ "$1" =~ "test_schema_stitching" ]]; then
		kill $REMOTE_GQL_PID || true
		wait $REMOTE_GQL_PID || true
	fi

	log "Run pytest for the current build $(cur_server_version) without modifying schema"
	run_pytest --skip-schema-setup --skip-schema-teardown

	log "kill the api server $(cur_server_version)"
	kill $HGE_PID || true
	wait $HGE_PID || true

	#################### Downgrade to release version ##########################

	log "Downgrade graphql-engine to $RELEASE_VERSION"
	$SERVER_BINARY downgrade "--to-$RELEASE_VERSION"

	############## Tests for latest release GraphQL engine once more after downgrade #########################

	if [[ "$1" =~ "test_schema_stitching" ]]; then
		python3 server/tests-py/graphql_server.py &
		REMOTE_GQL_PID=$!
		wait_for_port 5000
	fi

	# Start the old (latest release) GraphQL Engine
	log "starting latest graphql engine release"
	$LATEST_SERVER_BINARY serve >$LATEST_SERVER_LOG 2>&1 &
	HGE_PID=$!

	# Wait for server start
	wait_for_port $HASURA_GRAPHQL_SERVER_PORT $HGE_PID $LATEST_SERVER_LOG

	log "Catalog version for $(cur_server_version)"
	get_current_catalog_version

	if [[ "$1" =~ "test_schema_stitching" ]]; then
		kill $REMOTE_GQL_PID || true
		wait $REMOTE_GQL_PID || true
	fi

	log "Run pytest for latest graphql-engine release $(cur_server_version) (once more) while skipping schema setup"
	run_pytest --skip-schema-setup

	log "kill the api server $(cur_server_version)"
	kill $HGE_PID || true
	wait $HGE_PID || true

}

make_latest_release_worktree

# This seems to flake out relatively often; try a mirror if so.
# Might also need to disable ipv6 or use a longer --timeout
# cryptography 3.4.7 version requires Rust dependencies by default. But we don't need them for our tests, hence disabling them via the following env var => https://stackoverflow.com/a/66334084
export CRYPTOGRAPHY_DONT_BUILD_RUST=1

pip3 -q install -r "${PYTEST_DIR}/requirements.txt" ||
	pip3 -q install -i http://mirrors.digitalocean.com/pypi/web/simple --trusted-host mirrors.digitalocean.com -r "${PYTEST_DIR}/requirements.txt"


wait_for_postgres "$HASURA_GRAPHQL_DATABASE_URL"
cleanup_hasura_metadata_if_present

# We run_server_upgrade_pytest over each test individually to minimize the
# chance of breakage (e.g. where two different tests have conflicting
# setup.yaml which create the same table)
# This takes a long time.
for pytest in $(get_server_upgrade_tests); do
	log "Running pytest $pytest"
	run_server_upgrade_pytest "$pytest"
done

cleanup_hasura_metadata_if_present

exit 0
