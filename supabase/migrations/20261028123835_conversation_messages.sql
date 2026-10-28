create table public.conversation_messages (
    id bigint generated always as identity primary key,
    user_id uuid not null references auth.users(id) on delete cascade,
    session text not null check (char_length(session) between 1 and 100),
    role text not null check (role in ('user', 'assistant', 'summary')),
    content text not null check (char_length(content) between 1 and 20000),
    created_at timestamptz not null default now(),
    search_vector tsvector generated always as
        (to_tsvector('english'::regconfig, content)) stored
);
create index conversation_owner_session on public.conversation_messages (user_id, session, id desc);
create index conversation_search on public.conversation_messages using gin (search_vector);
alter table public.conversation_messages enable row level security;
revoke all on table public.conversation_messages from public, anon, authenticated;
grant select, insert, delete on table public.conversation_messages to authenticated;
revoke all on sequence public.conversation_messages_id_seq from public, anon, authenticated;
grant usage, select on sequence public.conversation_messages_id_seq to authenticated;
create policy conversation_select_own on public.conversation_messages for select to authenticated
    using ((select auth.uid()) = user_id);
create policy conversation_insert_own on public.conversation_messages for insert to authenticated
    with check ((select auth.uid()) = user_id);
create policy conversation_delete_own on public.conversation_messages for delete to authenticated
    using ((select auth.uid()) = user_id);

create table public.conversation_summaries (
    user_id uuid not null references auth.users(id) on delete cascade,
    session text not null check (char_length(session) between 1 and 100),
    through_id bigint not null,
    content text not null check (char_length(content) between 1 and 12000),
    primary key (user_id, session)
);
alter table public.conversation_summaries enable row level security;
revoke all on table public.conversation_summaries from public, anon, authenticated;
grant select, insert, update, delete on table public.conversation_summaries to authenticated;
create policy summary_select_own on public.conversation_summaries for select to authenticated
    using ((select auth.uid()) = user_id);
create policy summary_insert_own on public.conversation_summaries for insert to authenticated
    with check ((select auth.uid()) = user_id);
create policy summary_update_own on public.conversation_summaries for update to authenticated
    using ((select auth.uid()) = user_id)
    with check ((select auth.uid()) = user_id);
create policy summary_delete_own on public.conversation_summaries for delete to authenticated
    using ((select auth.uid()) = user_id);

create function public.conversation_enforce_quota()
returns trigger language plpgsql security invoker set search_path = '' as $$
begin
    perform pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtextextended(new.user_id::text, 20261029)
    );
    if (select count(*) from public.conversation_messages where user_id = new.user_id) >= 10000 then
        raise exception 'message quota exceeded';
    end if;
    return new;
end;
$$;
create trigger conversation_message_quota before insert on public.conversation_messages
for each row execute function public.conversation_enforce_quota();

create function public.conversation_add(p_session text, p_role text, p_content text)
returns bigint language plpgsql security invoker set search_path = '' as $$
declare v_id bigint;
begin
    if auth.uid() is null then raise exception 'sign in required'; end if;
    insert into public.conversation_messages(user_id, session, role, content)
    values (auth.uid(), p_session, p_role, p_content)
    returning id into v_id;
    return v_id;
end;
$$;

create function public.conversation_append_exchange(p_session text, p_user text, p_assistant text)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare v_user_id bigint; v_assistant_id bigint;
begin
    if auth.uid() is null then raise exception 'sign in required'; end if;
    insert into public.conversation_messages(user_id, session, role, content)
    values (auth.uid(), p_session, 'user', p_user) returning id into v_user_id;
    insert into public.conversation_messages(user_id, session, role, content)
    values (auth.uid(), p_session, 'assistant', p_assistant) returning id into v_assistant_id;
    return pg_catalog.jsonb_build_object('user_id', v_user_id, 'assistant_id', v_assistant_id);
end;
$$;

create function public.conversation_recent(p_session text, p_limit integer default 8)
returns table(id bigint, session text, role text, content text, created_at timestamptz)
language sql stable security invoker set search_path = '' as $$
    select m.id, m.session, m.role, m.content, m.created_at
    from public.conversation_messages m
    where m.user_id = (select auth.uid()) and m.session = p_session
    order by m.id desc limit least(greatest(coalesce(p_limit, 8), 1), 50);
$$;

create function public.conversation_recall(p_query text, p_exclude_session text default null)
returns table(id bigint, session text, role text, content text, created_at timestamptz, score real)
language sql stable security invoker set search_path = '' as $$
    select m.id, m.session, m.role, m.content, m.created_at,
           pg_catalog.ts_rank(m.search_vector, q.query)::real as score
    from public.conversation_messages m,
         pg_catalog.websearch_to_tsquery('english'::regconfig, left(p_query, 300)) as q(query)
    where m.user_id = (select auth.uid())
      and (p_exclude_session is null or m.session <> p_exclude_session)
      and m.search_vector @@ q.query
    order by score desc, m.id desc limit 4;
$$;

create function public.conversation_get_summary(p_session text)
returns table(through_id bigint, content text)
language sql stable security invoker set search_path = '' as $$
    select s.through_id, s.content from public.conversation_summaries s
    where s.user_id = (select auth.uid()) and s.session = p_session;
$$;

create function public.conversation_save_summary(p_session text, p_through_id bigint, p_content text)
returns void language plpgsql security invoker set search_path = '' as $$
begin
    if auth.uid() is null then raise exception 'sign in required'; end if;
    insert into public.conversation_summaries(user_id, session, through_id, content)
    values(auth.uid(), p_session, p_through_id, p_content)
    on conflict (user_id, session) do update
    set through_id = excluded.through_id, content = excluded.content;
end;
$$;

create function public.conversation_forget(p_session text)
returns integer language plpgsql security invoker set search_path = '' as $$
declare v_deleted integer;
begin
    if auth.uid() is null then raise exception 'sign in required'; end if;
    delete from public.conversation_messages
    where user_id = auth.uid() and session = p_session;
    get diagnostics v_deleted = row_count;
    delete from public.conversation_summaries
    where user_id = auth.uid() and session = p_session;
    return v_deleted;
end;
$$;

revoke all on function public.conversation_enforce_quota() from public, anon, authenticated;
revoke all on function public.conversation_add(text, text, text) from public, anon, authenticated;
revoke all on function public.conversation_append_exchange(text, text, text) from public, anon, authenticated;
revoke all on function public.conversation_recent(text, integer) from public, anon, authenticated;
revoke all on function public.conversation_recall(text, text) from public, anon, authenticated;
revoke all on function public.conversation_get_summary(text) from public, anon, authenticated;
revoke all on function public.conversation_save_summary(text, bigint, text) from public, anon, authenticated;
revoke all on function public.conversation_forget(text) from public, anon, authenticated;
grant execute on function public.conversation_add(text, text, text) to authenticated;
grant execute on function public.conversation_append_exchange(text, text, text) to authenticated;
grant execute on function public.conversation_recent(text, integer) to authenticated;
grant execute on function public.conversation_recall(text, text) to authenticated;
grant execute on function public.conversation_get_summary(text) to authenticated;
grant execute on function public.conversation_save_summary(text, bigint, text) to authenticated;
grant execute on function public.conversation_forget(text) to authenticated;
