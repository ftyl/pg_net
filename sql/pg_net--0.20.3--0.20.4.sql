create unlogged table if not exists net.http_request_inflight(
    id bigint primary key,
    method net.http_method not null,
    url text not null,
    headers jsonb,
    body bytea,
    timeout_milliseconds int not null,
    lease_expires_at timestamptz not null
);

create index if not exists http_request_inflight_lease_expires_at_idx
    on net.http_request_inflight (lease_expires_at);

grant all on table net.http_request_inflight to public;
