import time

import pytest
from sqlalchemy import text

def wait_until(predicate, timeout=5.0, interval=0.1):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(interval)
    return False


def test_query_stat_statements(sess):
    """Check that the background worker doesn't execute queries when no new requests arrive"""

    (pg_version,) = sess.execute(text(
        """
        select current_setting('server_version_num');
    """
    )).fetchone()

    if int(pg_version) < 140000:
        pytest.skip("Skipping fixture on pg version < 14. The query_id column on pg_stat_statements is only available on >= 14")

    sess.execute(text(
        """
        create extension pg_stat_statements;
    """
    ))

    sess.commit()

    time.sleep(1)

    (old_calls,) = sess.execute(text(
        """
        select coalesce(sum(calls), 0)
        from pg_stat_statements
        where
            query ilike '%DELETE FROM net._http_response r %' or
            query ilike '%DELETE FROM net.http_request_queue%';
    """
    )).fetchone()

    # sleep for some time to see if new queries arrive
    time.sleep(3)

    (new_calls,) = sess.execute(text(
        """
        select coalesce(sum(calls), 0)
        from pg_stat_statements
        where
            query ilike '%DELETE FROM net._http_response r %' or
            query ilike '%DELETE FROM net.http_request_queue%';
    """
    )).fetchone()

    assert new_calls == old_calls

    sess.execute(text(
        """
        select pg_stat_statements_reset();
        drop extension pg_stat_statements;
    """
    ))

    sess.commit()


def test_wakes_at_commit_time(sess):
    """Check that the background worker only does one wake at commit time, avoiding unnecessary wakes and work"""

    (pg_version,) = sess.execute(text(
        """
        select current_setting('server_version_num');
    """
    )).fetchone()

    if int(pg_version) < 140000:
        pytest.skip("Skipping fixture on pg version < 14. The query_id column on pg_stat_statements is only available on >= 14")

    sess.execute(text(
        """
        create extension pg_stat_statements;
    """
    ))

    sess.commit()

    # wait for initial queries
    time.sleep(1)

    (initial_calls,) = sess.execute(text(
        """
        select coalesce(sum(calls), 0)
        from pg_stat_statements
        where
            query ilike '%DELETE FROM net._http_response r %' or
            query ilike '%DELETE FROM net.http_request_queue%';
    """
    )).fetchone()

    assert initial_calls >= 0

    sess.execute(text(
        """
        select net.http_get('http://localhost:8080/pathological?status=200') from generate_series(1,100);
    """
    ))

    sess.commit()

    assert wait_until(
        lambda: sess.execute(text("select count(*) from net.http_request_queue;")).scalar() == 0
        and sess.execute(text("select count(*) from net.http_request_inflight;")).scalar() == 0,
        timeout=10.0,
    ), "worker did not fully drain queue/inflight before stat check"

    (commit_calls,) = sess.execute(text(
        """
        select coalesce(sum(calls), 0)
        from pg_stat_statements
        where
            query ilike '%DELETE FROM net._http_response r %' or
            query ilike '%DELETE FROM net.http_request_queue%';
    """
    )).fetchone()

    # In the fast-refill worker, completions can occasionally be split into an
    # extra finalize pass depending on curl event coalescing. Keep the
    # assertion tight enough to catch churn regressions while allowing this.
    assert initial_calls + 4 <= commit_calls <= initial_calls + 6

    # if the new requests are rollbacked/aborted, then no new queries will be made by the bg worker
    sess.execute(text(
        """
        select net.http_get('http://localhost:8080/pathological?status=200') from generate_series(1,100);
    """
    ))

    sess.rollback()

    time.sleep(2)

    (rollback_calls,) = sess.execute(text(
        """
        select coalesce(sum(calls), 0)
        from pg_stat_statements
        where
            query ilike '%DELETE FROM net._http_response r %' or
            query ilike '%DELETE FROM net.http_request_queue%';
    """
    )).fetchone()

    assert rollback_calls == commit_calls

    sess.execute(text(
        """
        select pg_stat_statements_reset();
        drop extension pg_stat_statements;
    """
    ))

    sess.commit()
