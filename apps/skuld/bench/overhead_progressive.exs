# Progressive Overhead Benchmark
#
# Run with: MIX_ENV=prod mix run bench/overhead_progressive.exs
#
# Starts from the flat evidence-passing CPS baseline and progressively adds
# one Skuld feature at a time, measuring the marginal cost of each addition.
#
# This isolates exactly where the ~6x overhead between flat evf_cps and
# Skuld comes from. See issue skuld-dxs.
#
# Each step builds on the previous:
#
# Step 0: evf_cps        — baseline: direct fn calls, plain map, no catch
# Step 1: + catch/call   — add catch frame around computation invocation
# Step 2: + catch/bind   — add try/catch in bind around f.(a) + next call
# Step 3: + catch/handler — add catch frame around handler dispatch
# Step 4: + guard        — add is_function(comp, 2) guard (auto-lifting)
# Step 5: + struct env   — use %Env{} struct instead of plain map
# Step 6: + struct args  — use %Get{tag:}/%Put{tag:,value:} structs for ops
# Step 7: + accessors    — use Env.get_state!/put_state instead of direct map
# Step 8: + Change struct — allocate %Change{old:,new:} on put (like real State)
# Step 9: + state_key    — use {Mod, tag} tuple keys (like real State)
# Step 10: Full Skuld    — actual Skuld for comparison

alias Skuld.Comp
alias Skuld.Effects.State, as: SkuldState

defmodule OverheadBenchmark do
  # ============================================================
  # Shared error handler (used by steps that add catch frames)
  # ============================================================

  defp handle_error(_kind, _payload, env) do
    # Simplified version of ConvertThrow.handle_exception
    # Just return a throw-like result - we never actually hit this
    # on the happy path, but the catch frame setup cost is real.
    {:throw, env}
  end

  # ============================================================
  # Step 0: evf_cps baseline (from existing benchmark)
  # Direct fn calls, plain map env, no catch frames
  # ============================================================

  def s0_pure(value), do: fn env, k -> k.(value, env) end

  def s0_bind(ma, f) do
    fn env, k ->
      ma.(env, fn a, env2 ->
        f.(a).(env2, k)
      end)
    end
  end

  def s0_run(ma, env), do: ma.(env, fn v, e -> {v, e} end)

  def s0_get(), do: fn env, k -> env.state_get.(env, k) end
  def s0_put(value), do: fn env, k -> env.state_put.(value, env, k) end

  def s0_with_state(initial, comp) do
    fn env, k ->
      inner =
        env
        |> Map.put(:state, initial)
        |> Map.put(:state_get, fn e, k -> k.(e.state, e) end)
        |> Map.put(:state_put, fn v, e, k -> k.(:ok, %{e | state: v}) end)

      comp.(inner, fn result, final ->
        k.(result, Map.drop(final, [:state, :state_get, :state_put]))
      end)
    end
  end

  def s0_loop(target) do
    s0_get()
    |> s0_bind(fn n ->
      if n >= target, do: s0_pure(n), else: s0_put(n + 1) |> s0_bind(fn _ -> s0_loop(target) end)
    end)
  end

  def s0(target), do: s0_with_state(0, s0_loop(target))

  # ============================================================
  # Step 1: + catch frame on call
  # ============================================================

  def s1_call(comp, env, k) do
    comp.(env, k)
  catch
    kind, payload -> handle_error(kind, payload, env)
  end

  def s1_pure(value), do: fn env, k -> k.(value, env) end

  def s1_bind(ma, f) do
    fn env, k ->
      s1_call(ma, env, fn a, env2 ->
        # No catch here yet - that's step 2
        f.(a).(env2, k)
      end)
    end
  end

  def s1_run(ma, env), do: ma.(env, fn v, e -> {v, e} end)

  def s1_get(), do: fn env, k -> env.state_get.(env, k) end
  def s1_put(value), do: fn env, k -> env.state_put.(value, env, k) end

  def s1_with_state(initial, comp) do
    fn env, k ->
      inner =
        env
        |> Map.put(:state, initial)
        |> Map.put(:state_get, fn e, k -> k.(e.state, e) end)
        |> Map.put(:state_put, fn v, e, k -> k.(:ok, %{e | state: v}) end)

      comp.(inner, fn result, final ->
        k.(result, Map.drop(final, [:state, :state_get, :state_put]))
      end)
    end
  end

  def s1_loop(target) do
    s1_get()
    |> s1_bind(fn n ->
      if n >= target, do: s1_pure(n), else: s1_put(n + 1) |> s1_bind(fn _ -> s1_loop(target) end)
    end)
  end

  def s1(target), do: s1_with_state(0, s1_loop(target))

  # ============================================================
  # Step 2: + catch frame in bind (around f.(a) + next call)
  # ============================================================

  def s2_call(comp, env, k) do
    comp.(env, k)
  catch
    kind, payload -> handle_error(kind, payload, env)
  end

  def s2_pure(value), do: fn env, k -> k.(value, env) end

  def s2_bind(ma, f) do
    fn env, k ->
      s2_call(ma, env, fn a, env2 ->
        try do
          result = f.(a)
          s2_call(result, env2, k)
        catch
          kind, payload -> handle_error(kind, payload, env2)
        end
      end)
    end
  end

  def s2_run(ma, env), do: ma.(env, fn v, e -> {v, e} end)

  def s2_get(), do: fn env, k -> env.state_get.(env, k) end
  def s2_put(value), do: fn env, k -> env.state_put.(value, env, k) end

  def s2_with_state(initial, comp) do
    fn env, k ->
      inner =
        env
        |> Map.put(:state, initial)
        |> Map.put(:state_get, fn e, k -> k.(e.state, e) end)
        |> Map.put(:state_put, fn v, e, k -> k.(:ok, %{e | state: v}) end)

      comp.(inner, fn result, final ->
        k.(result, Map.drop(final, [:state, :state_get, :state_put]))
      end)
    end
  end

  def s2_loop(target) do
    s2_get()
    |> s2_bind(fn n ->
      if n >= target, do: s2_pure(n), else: s2_put(n + 1) |> s2_bind(fn _ -> s2_loop(target) end)
    end)
  end

  def s2(target), do: s2_with_state(0, s2_loop(target))

  # ============================================================
  # Step 3: + catch frame on handler dispatch
  # ============================================================

  def s3_call(comp, env, k) do
    comp.(env, k)
  catch
    kind, payload -> handle_error(kind, payload, env)
  end

  def s3_call_handler(handler, args, env, k) do
    handler.(args, env, k)
  catch
    kind, payload -> handle_error(kind, payload, env)
  end

  def s3_pure(value), do: fn env, k -> k.(value, env) end

  def s3_bind(ma, f) do
    fn env, k ->
      s3_call(ma, env, fn a, env2 ->
        try do
          result = f.(a)
          s3_call(result, env2, k)
        catch
          kind, payload -> handle_error(kind, payload, env2)
        end
      end)
    end
  end

  def s3_run(ma, env), do: ma.(env, fn v, e -> {v, e} end)

  # Effect operations now go through call_handler
  def s3_effect(sig) do
    fn env, k ->
      handler = env[sig]
      s3_call_handler(handler, sig, env, k)
    end
  end

  def s3_effect(sig, args) do
    fn env, k ->
      handler = env[sig]
      s3_call_handler(handler, args, env, k)
    end
  end

  def s3_with_state(initial, comp) do
    fn env, k ->
      handler = fn args, inner_env, k ->
        case args do
          :get -> k.(inner_env.state, inner_env)
          {:put, v} -> k.(:ok, %{inner_env | state: v})
        end
      end

      inner =
        env
        |> Map.put(:state, initial)
        |> Map.put(:state_handler, handler)

      comp.(inner, fn result, final ->
        k.(result, Map.drop(final, [:state, :state_handler]))
      end)
    end
  end

  def s3_loop(target) do
    s3_effect(:state_handler, :get)
    |> s3_bind(fn n ->
      if n >= target do
        s3_pure(n)
      else
        s3_effect(:state_handler, {:put, n + 1})
        |> s3_bind(fn _ -> s3_loop(target) end)
      end
    end)
  end

  def s3(target), do: s3_with_state(0, s3_loop(target))

  # ============================================================
  # Step 4: + is_function guard (auto-lifting)
  # ============================================================

  def s4_call(comp, env, k) when is_function(comp, 2) do
    comp.(env, k)
  catch
    kind, payload -> handle_error(kind, payload, env)
  end

  def s4_call(value, env, k) do
    k.(value, env)
  catch
    kind, payload -> handle_error(kind, payload, env)
  end

  def s4_call_handler(handler, args, env, k) when is_function(handler, 3) do
    handler.(args, env, k)
  catch
    kind, payload -> handle_error(kind, payload, env)
  end

  def s4_pure(value), do: fn env, k -> k.(value, env) end

  def s4_bind(ma, f) do
    fn env, k ->
      s4_call(ma, env, fn a, env2 ->
        try do
          result = f.(a)
          s4_call(result, env2, k)
        catch
          kind, payload -> handle_error(kind, payload, env2)
        end
      end)
    end
  end

  def s4_run(ma, env), do: ma.(env, fn v, e -> {v, e} end)

  def s4_effect(sig, args) do
    fn env, k ->
      handler = env[sig]
      s4_call_handler(handler, args, env, k)
    end
  end

  def s4_with_state(initial, comp) do
    fn env, k ->
      handler = fn args, inner_env, k ->
        case args do
          :get -> k.(inner_env.state, inner_env)
          {:put, v} -> k.(:ok, %{inner_env | state: v})
        end
      end

      inner =
        env
        |> Map.put(:state, initial)
        |> Map.put(:state_handler, handler)

      comp.(inner, fn result, final ->
        k.(result, Map.drop(final, [:state, :state_handler]))
      end)
    end
  end

  def s4_loop(target) do
    s4_effect(:state_handler, :get)
    |> s4_bind(fn n ->
      if n >= target do
        s4_pure(n)
      else
        s4_effect(:state_handler, {:put, n + 1})
        |> s4_bind(fn _ -> s4_loop(target) end)
      end
    end)
  end

  def s4(target), do: s4_with_state(0, s4_loop(target))

  # ============================================================
  # Step 5: + struct env (%Env{} instead of plain map)
  # Uses a minimal struct with :evidence and :state fields
  # ============================================================

  defmodule S5Env do
    defstruct evidence: %{}, state: %{}
  end

  def s5_call(comp, env, k) when is_function(comp, 2) do
    comp.(env, k)
  catch
    kind, payload -> handle_error(kind, payload, env)
  end

  def s5_call(value, env, k) do
    k.(value, env)
  catch
    kind, payload -> handle_error(kind, payload, env)
  end

  def s5_call_handler(handler, args, env, k) when is_function(handler, 3) do
    handler.(args, env, k)
  catch
    kind, payload -> handle_error(kind, payload, env)
  end

  def s5_pure(value), do: fn env, k -> k.(value, env) end

  def s5_bind(ma, f) do
    fn env, k ->
      s5_call(ma, env, fn a, env2 ->
        try do
          result = f.(a)
          s5_call(result, env2, k)
        catch
          kind, payload -> handle_error(kind, payload, env2)
        end
      end)
    end
  end

  def s5_run(ma, env), do: ma.(env, fn v, e -> {v, e} end)

  def s5_effect(sig, args) do
    fn env, k ->
      handler = env.evidence[sig]
      s5_call_handler(handler, args, env, k)
    end
  end

  def s5_with_state(initial, comp) do
    fn env, k ->
      handler = fn args, inner_env, k ->
        case args do
          :get -> k.(inner_env.state, inner_env)
          {:put, v} -> k.(:ok, %{inner_env | state: v})
        end
      end

      inner = %S5Env{evidence: Map.put(env.evidence, :state_handler, handler), state: initial}

      comp.(inner, fn result, _final ->
        k.(result, env)
      end)
    end
  end

  def s5_loop(target) do
    s5_effect(:state_handler, :get)
    |> s5_bind(fn n ->
      if n >= target do
        s5_pure(n)
      else
        s5_effect(:state_handler, {:put, n + 1})
        |> s5_bind(fn _ -> s5_loop(target) end)
      end
    end)
  end

  def s5(target), do: s5_with_state(0, s5_loop(target))

  # ============================================================
  # Step 5c: compact ops with per-tag module-atom sig
  # Like S5 but handler is installed per-tag using module-atom sigs
  # (e.g. State.Counter) — still just atoms, so evidence lookup is
  # atom-keyed. Operations use module-atom ops for dispatch:
  #   get: Comp.effect(State.Counter, State.Counter.Get)
  #   put: Comp.effect(State.Counter, {State.Counter.Put, value})
  # Handler closes over state_key — no tag in args.
  # ============================================================

  # Simulate module-atom construction: these are just atoms, no defmodule needed
  defmodule S5cState do
    # Tag-specific sig atom (like State.Default)
    defmodule Default do
      # Op atoms (like State.Default.Get / State.Default.Put)
      defmodule Get do
      end

      defmodule Put do
      end
    end
  end

  @s5c_sig S5cState.Default
  @s5c_get_op S5cState.Default.Get
  @s5c_put_op S5cState.Default.Put

  def s5c_call(comp, env, k) when is_function(comp, 2) do
    comp.(env, k)
  catch
    kind, payload -> handle_error(kind, payload, env)
  end

  def s5c_call(value, env, k) do
    k.(value, env)
  catch
    kind, payload -> handle_error(kind, payload, env)
  end

  def s5c_call_handler(handler, args, env, k) when is_function(handler, 3) do
    handler.(args, env, k)
  catch
    kind, payload -> handle_error(kind, payload, env)
  end

  def s5c_pure(value), do: fn env, k -> k.(value, env) end

  def s5c_bind(ma, f) do
    fn env, k ->
      s5c_call(ma, env, fn a, env2 ->
        try do
          result = f.(a)
          s5c_call(result, env2, k)
        catch
          kind, payload -> handle_error(kind, payload, env2)
        end
      end)
    end
  end

  def s5c_run(ma, env), do: ma.(env, fn v, e -> {v, e} end)

  def s5c_effect(sig, args) do
    fn env, k ->
      handler = env.evidence[sig]
      s5c_call_handler(handler, args, env, k)
    end
  end

  # Operations: sig is an atom, get op is a bare atom, put op is {atom, value}
  def s5c_get(), do: s5c_effect(@s5c_sig, @s5c_get_op)
  def s5c_put(value), do: s5c_effect(@s5c_sig, {@s5c_put_op, value})

  def s5c_with_state(initial, comp) do
    fn env, k ->
      state_key = @s5c_sig

      # Handler closes over state_key — dispatches on op atoms
      handler = fn args, inner_env, k ->
        case args do
          @s5c_get_op ->
            value = Map.fetch!(inner_env.state, state_key)
            k.(value, inner_env)

          {@s5c_put_op, value} ->
            new_env = %{inner_env | state: Map.put(inner_env.state, state_key, value)}
            k.(:ok, new_env)
        end
      end

      inner = %S5Env{
        evidence: Map.put(env.evidence, @s5c_sig, handler),
        state: Map.put(%{}, state_key, initial)
      }

      comp.(inner, fn result, _final ->
        k.(result, env)
      end)
    end
  end

  def s5c_loop(target) do
    s5c_get()
    |> s5c_bind(fn n ->
      if n >= target do
        s5c_pure(n)
      else
        s5c_put(n + 1)
        |> s5c_bind(fn _ -> s5c_loop(target) end)
      end
    end)
  end

  def s5c(target), do: s5c_with_state(0, s5c_loop(target))

  # ============================================================
  # Step 6: + struct args (%Get{} / %Put{} instead of atoms/tuples)
  # ============================================================

  defmodule Get do
    defstruct [:tag]
  end

  defmodule Put do
    defstruct [:tag, :value]
  end

  def s6_call(comp, env, k) when is_function(comp, 2) do
    comp.(env, k)
  catch
    kind, payload -> handle_error(kind, payload, env)
  end

  def s6_call(value, env, k) do
    k.(value, env)
  catch
    kind, payload -> handle_error(kind, payload, env)
  end

  def s6_call_handler(handler, args, env, k) when is_function(handler, 3) do
    handler.(args, env, k)
  catch
    kind, payload -> handle_error(kind, payload, env)
  end

  def s6_pure(value), do: fn env, k -> k.(value, env) end

  def s6_bind(ma, f) do
    fn env, k ->
      s6_call(ma, env, fn a, env2 ->
        try do
          result = f.(a)
          s6_call(result, env2, k)
        catch
          kind, payload -> handle_error(kind, payload, env2)
        end
      end)
    end
  end

  def s6_run(ma, env), do: ma.(env, fn v, e -> {v, e} end)

  def s6_effect(sig, args) do
    fn env, k ->
      handler = env.evidence[sig]
      s6_call_handler(handler, args, env, k)
    end
  end

  def s6_get(tag \\ :default), do: s6_effect(:state_handler, %Get{tag: tag})
  def s6_put(tag \\ :default, value), do: s6_effect(:state_handler, %Put{tag: tag, value: value})

  def s6_with_state(initial, comp) do
    fn env, k ->
      handler = fn args, inner_env, k ->
        case args do
          %Get{} -> k.(inner_env.state, inner_env)
          %Put{value: v} -> k.(:ok, %{inner_env | state: v})
        end
      end

      inner = %S5Env{evidence: Map.put(env.evidence, :state_handler, handler), state: initial}

      comp.(inner, fn result, _final ->
        k.(result, env)
      end)
    end
  end

  def s6_loop(target) do
    s6_get()
    |> s6_bind(fn n ->
      if n >= target do
        s6_pure(n)
      else
        s6_put(:default, n + 1)
        |> s6_bind(fn _ -> s6_loop(target) end)
      end
    end)
  end

  def s6(target), do: s6_with_state(0, s6_loop(target))

  # ============================================================
  # Step 6t: tagged-tuple args ({GetTag, tag} / {PutTag, tag, value})
  # Same as S6 but uses tagged tuples instead of structs
  # ============================================================

  defmodule GetTag do
  end

  defmodule PutTag do
  end

  def s6t_call(comp, env, k) when is_function(comp, 2) do
    comp.(env, k)
  catch
    kind, payload -> handle_error(kind, payload, env)
  end

  def s6t_call(value, env, k) do
    k.(value, env)
  catch
    kind, payload -> handle_error(kind, payload, env)
  end

  def s6t_call_handler(handler, args, env, k) when is_function(handler, 3) do
    handler.(args, env, k)
  catch
    kind, payload -> handle_error(kind, payload, env)
  end

  def s6t_pure(value), do: fn env, k -> k.(value, env) end

  def s6t_bind(ma, f) do
    fn env, k ->
      s6t_call(ma, env, fn a, env2 ->
        try do
          result = f.(a)
          s6t_call(result, env2, k)
        catch
          kind, payload -> handle_error(kind, payload, env2)
        end
      end)
    end
  end

  def s6t_run(ma, env), do: ma.(env, fn v, e -> {v, e} end)

  def s6t_effect(sig, args) do
    fn env, k ->
      handler = env.evidence[sig]
      s6t_call_handler(handler, args, env, k)
    end
  end

  def s6t_get(tag \\ :default), do: s6t_effect(:state_handler, {GetTag, tag})

  def s6t_put(tag \\ :default, value),
    do: s6t_effect(:state_handler, {PutTag, tag, value})

  def s6t_with_state(initial, comp) do
    fn env, k ->
      handler = fn args, inner_env, k ->
        case args do
          {GetTag, _tag} -> k.(inner_env.state, inner_env)
          {PutTag, _tag, v} -> k.(:ok, %{inner_env | state: v})
        end
      end

      inner = %S5Env{evidence: Map.put(env.evidence, :state_handler, handler), state: initial}

      comp.(inner, fn result, _final ->
        k.(result, env)
      end)
    end
  end

  def s6t_loop(target) do
    s6t_get()
    |> s6t_bind(fn n ->
      if n >= target do
        s6t_pure(n)
      else
        s6t_put(:default, n + 1)
        |> s6t_bind(fn _ -> s6t_loop(target) end)
      end
    end)
  end

  def s6t(target), do: s6t_with_state(0, s6t_loop(target))

  # ============================================================
  # Step 7: + accessor functions (Env.get_state!/put_state style)
  # Nested map access: env.state is a map keyed by state_key
  # ============================================================

  defmodule S7Env do
    defstruct evidence: %{}, state: %{}
  end

  def s7_get_state!(env, key) do
    case Map.fetch(env.state, key) do
      {:ok, value} -> value
      :error -> raise "State not found for key #{inspect(key)}"
    end
  end

  def s7_put_state(env, key, value) do
    %{env | state: Map.put(env.state, key, value)}
  end

  def s7_get_handler!(env, sig) do
    case env.evidence[sig] do
      nil -> raise "No handler for #{inspect(sig)}"
      handler -> handler
    end
  end

  def s7_call(comp, env, k) when is_function(comp, 2) do
    comp.(env, k)
  catch
    kind, payload -> handle_error(kind, payload, env)
  end

  def s7_call(value, env, k) do
    k.(value, env)
  catch
    kind, payload -> handle_error(kind, payload, env)
  end

  def s7_call_handler(handler, args, env, k) when is_function(handler, 3) do
    handler.(args, env, k)
  catch
    kind, payload -> handle_error(kind, payload, env)
  end

  def s7_pure(value), do: fn env, k -> k.(value, env) end

  def s7_bind(ma, f) do
    fn env, k ->
      s7_call(ma, env, fn a, env2 ->
        try do
          result = f.(a)
          s7_call(result, env2, k)
        catch
          kind, payload -> handle_error(kind, payload, env2)
        end
      end)
    end
  end

  def s7_run(ma, env), do: ma.(env, fn v, e -> {v, e} end)

  def s7_effect(sig, args) do
    fn env, k ->
      handler = s7_get_handler!(env, sig)
      s7_call_handler(handler, args, env, k)
    end
  end

  def s7_get(tag \\ :default), do: s7_effect(:state_handler, %Get{tag: tag})
  def s7_put(tag \\ :default, value), do: s7_effect(:state_handler, %Put{tag: tag, value: value})

  @state_key :s7_state

  def s7_with_state(initial, comp) do
    fn env, k ->
      handler = fn args, inner_env, k ->
        case args do
          %Get{} ->
            value = s7_get_state!(inner_env, @state_key)
            k.(value, inner_env)

          %Put{value: v} ->
            new_env = s7_put_state(inner_env, @state_key, v)
            k.(:ok, new_env)
        end
      end

      inner = %S7Env{
        evidence: Map.put(env.evidence, :state_handler, handler),
        state: %{@state_key => initial}
      }

      comp.(inner, fn result, _final ->
        k.(result, env)
      end)
    end
  end

  def s7_loop(target) do
    s7_get()
    |> s7_bind(fn n ->
      if n >= target do
        s7_pure(n)
      else
        s7_put(:default, n + 1)
        |> s7_bind(fn _ -> s7_loop(target) end)
      end
    end)
  end

  def s7(target), do: s7_with_state(0, s7_loop(target))

  # ============================================================
  # Step 8: + Change struct (allocate %Change{old:,new:} on put)
  # ============================================================

  defmodule Change do
    defstruct [:old, :new]
  end

  def s8_call(comp, env, k) when is_function(comp, 2) do
    comp.(env, k)
  catch
    kind, payload -> handle_error(kind, payload, env)
  end

  def s8_call(value, env, k) do
    k.(value, env)
  catch
    kind, payload -> handle_error(kind, payload, env)
  end

  def s8_call_handler(handler, args, env, k) when is_function(handler, 3) do
    handler.(args, env, k)
  catch
    kind, payload -> handle_error(kind, payload, env)
  end

  def s8_pure(value), do: fn env, k -> k.(value, env) end

  def s8_bind(ma, f) do
    fn env, k ->
      s8_call(ma, env, fn a, env2 ->
        try do
          result = f.(a)
          s8_call(result, env2, k)
        catch
          kind, payload -> handle_error(kind, payload, env2)
        end
      end)
    end
  end

  def s8_run(ma, env), do: ma.(env, fn v, e -> {v, e} end)

  def s8_effect(sig, args) do
    fn env, k ->
      handler = s7_get_handler!(env, sig)
      s8_call_handler(handler, args, env, k)
    end
  end

  def s8_get(tag \\ :default), do: s8_effect(:state_handler, %Get{tag: tag})
  def s8_put(tag \\ :default, value), do: s8_effect(:state_handler, %Put{tag: tag, value: value})

  @state_key8 :s8_state

  def s8_with_state(initial, comp) do
    fn env, k ->
      handler = fn args, inner_env, k ->
        case args do
          %Get{} ->
            value = s7_get_state!(inner_env, @state_key8)
            k.(value, inner_env)

          %Put{value: v} ->
            old = s7_get_state!(inner_env, @state_key8)
            new_env = s7_put_state(inner_env, @state_key8, v)
            k.(%Change{old: old, new: v}, new_env)
        end
      end

      inner = %S7Env{
        evidence: Map.put(env.evidence, :state_handler, handler),
        state: %{@state_key8 => initial}
      }

      comp.(inner, fn result, _final ->
        k.(result, env)
      end)
    end
  end

  def s8_loop(target) do
    s8_get()
    |> s8_bind(fn n ->
      if n >= target do
        s8_pure(n)
      else
        s8_put(:default, n + 1)
        |> s8_bind(fn _ -> s8_loop(target) end)
      end
    end)
  end

  def s8(target), do: s8_with_state(0, s8_loop(target))

  # ============================================================
  # Step 9: + state_key tuple ({Mod, tag} keys like real State)
  # ============================================================

  def s9_state_key(tag), do: {__MODULE__, tag}

  def s9_call(comp, env, k) when is_function(comp, 2) do
    comp.(env, k)
  catch
    kind, payload -> handle_error(kind, payload, env)
  end

  def s9_call(value, env, k) do
    k.(value, env)
  catch
    kind, payload -> handle_error(kind, payload, env)
  end

  def s9_call_handler(handler, args, env, k) when is_function(handler, 3) do
    handler.(args, env, k)
  catch
    kind, payload -> handle_error(kind, payload, env)
  end

  def s9_pure(value), do: fn env, k -> k.(value, env) end

  def s9_bind(ma, f) do
    fn env, k ->
      s9_call(ma, env, fn a, env2 ->
        try do
          result = f.(a)
          s9_call(result, env2, k)
        catch
          kind, payload -> handle_error(kind, payload, env2)
        end
      end)
    end
  end

  def s9_run(ma, env), do: ma.(env, fn v, e -> {v, e} end)

  def s9_effect(sig, args) do
    fn env, k ->
      handler = s7_get_handler!(env, sig)
      s9_call_handler(handler, args, env, k)
    end
  end

  def s9_get(tag \\ :default), do: s9_effect(:state_handler, %Get{tag: tag})
  def s9_put(tag \\ :default, value), do: s9_effect(:state_handler, %Put{tag: tag, value: value})

  def s9_with_state(initial, comp) do
    fn env, k ->
      handler = fn args, inner_env, k ->
        case args do
          %Get{tag: tag} ->
            key = s9_state_key(tag)
            value = s7_get_state!(inner_env, key)
            k.(value, inner_env)

          %Put{tag: tag, value: v} ->
            key = s9_state_key(tag)
            old = s7_get_state!(inner_env, key)
            new_env = s7_put_state(inner_env, key, v)
            k.(%Change{old: old, new: v}, new_env)
        end
      end

      key = s9_state_key(:default)

      inner = %S7Env{
        evidence: Map.put(env.evidence, :state_handler, handler),
        state: %{key => initial}
      }

      comp.(inner, fn result, _final ->
        k.(result, env)
      end)
    end
  end

  def s9_loop(target) do
    s9_get()
    |> s9_bind(fn n ->
      if n >= target do
        s9_pure(n)
      else
        s9_put(:default, n + 1)
        |> s9_bind(fn _ -> s9_loop(target) end)
      end
    end)
  end

  def s9(target), do: s9_with_state(0, s9_loop(target))

  # ============================================================
  # Step 10: Full Skuld (from existing benchmark)
  # ============================================================

  def s10_loop(target) do
    SkuldState.get()
    |> Comp.bind(fn n ->
      if n >= target do
        Comp.pure(n)
      else
        SkuldState.put(n + 1)
        |> Comp.bind(fn _ -> s10_loop(target) end)
      end
    end)
  end

  def s10(target), do: s10_loop(target) |> SkuldState.with_handler(0)

  # ============================================================
  # Timing
  # ============================================================

  def time(fun), do: :timer.tc(fun)

  def median_time(iterations, fun) do
    times = for _ <- 1..iterations, do: elem(fun.(), 0)
    times |> Enum.sort() |> Enum.at(div(iterations, 2))
  end

  defp format_time(us) when us < 1_000, do: "#{us} us"
  defp format_time(us) when us < 1_000_000, do: "#{Float.round(us / 1_000, 1)} ms"
  defp format_time(us), do: "#{Float.round(us / 1_000_000, 2)} s"

  # ============================================================
  # Runner
  # ============================================================

  def run(targets \\ [1_000, 5_000, 10_000]) do
    IO.puts("Progressive Overhead Benchmark (skuld-dxs)")
    IO.puts("============================================")
    IO.puts("")
    IO.puts("Each step adds one feature to the evf_cps baseline.")
    IO.puts("Delta shows the marginal cost of that feature.")
    IO.puts("")

    iterations = 7

    # Warmup
    IO.puts("Warming up...")

    for _ <- 1..3 do
      for target <- [100] do
        _ = time(fn -> s0_run(s0(target), %{}) end)
        _ = time(fn -> s1_run(s1(target), %{}) end)
        _ = time(fn -> s2_run(s2(target), %{}) end)
        _ = time(fn -> s3_run(s3(target), %{}) end)
        _ = time(fn -> s4_run(s4(target), %{}) end)
        _ = time(fn -> s5_run(s5(target), %S5Env{}) end)
        _ = time(fn -> s5c_run(s5c(target), %S5Env{}) end)
        _ = time(fn -> s6_run(s6(target), %S5Env{}) end)
        _ = time(fn -> s6t_run(s6t(target), %S5Env{}) end)
        _ = time(fn -> s7_run(s7(target), %S7Env{}) end)
        _ = time(fn -> s8_run(s8(target), %S7Env{}) end)
        _ = time(fn -> s9_run(s9(target), %S7Env{}) end)
        _ = time(fn -> Comp.run(s10(target)) end)
      end
    end

    IO.puts("")

    steps = [
      {"S0: evf_cps baseline", fn t -> s0_run(s0(t), %{}) end},
      {"S1: + catch/call", fn t -> s1_run(s1(t), %{}) end},
      {"S2: + catch/bind", fn t -> s2_run(s2(t), %{}) end},
      {"S3: + catch/handler", fn t -> s3_run(s3(t), %{}) end},
      {"S4: + guard", fn t -> s4_run(s4(t), %{}) end},
      {"S5: + struct env", fn t -> s5_run(s5(t), %S5Env{}) end},
      {"S5c: + per-tag sig", fn t -> s5c_run(s5c(t), %S5Env{}) end},
      {"S6: + struct args", fn t -> s6_run(s6(t), %S5Env{}) end},
      {"S6t: + tagged-tuple args", fn t -> s6t_run(s6t(t), %S5Env{}) end},
      {"S7: + accessors", fn t -> s7_run(s7(t), %S7Env{}) end},
      {"S8: + Change struct", fn t -> s8_run(s8(t), %S7Env{}) end},
      {"S9: + state_key tuple", fn t -> s9_run(s9(t), %S7Env{}) end},
      {"S10: Full Skuld", fn t -> Comp.run(s10(t)) end}
    ]

    for target <- targets do
      IO.puts("")
      IO.puts("N=#{target}")

      IO.puts(
        String.pad_trailing("Step", 28) <>
          String.pad_trailing("Time", 12) <>
          String.pad_trailing("us/op", 10) <>
          String.pad_trailing("Delta", 12) <>
          "vs baseline"
      )

      IO.puts(String.duplicate("-", 75))

      prev_time = nil

      {_, baseline_time} =
        Enum.reduce(steps, {prev_time, nil}, fn {label, runner}, {prev, baseline} ->
          # Pre-build the computation outside the timing loop
          t =
            median_time(iterations, fn ->
              time(fn -> runner.(target) end)
            end)

          per_op = Float.round(t / target, 3)
          baseline = baseline || t
          ratio = Float.round(t / baseline, 1)

          delta =
            if prev do
              d = t - prev
              sign = if d >= 0, do: "+", else: ""
              "#{sign}#{format_time(abs(d))}"
            else
              "-"
            end

          IO.puts(
            String.pad_trailing(label, 28) <>
              String.pad_trailing(format_time(t), 12) <>
              String.pad_trailing("#{per_op}", 10) <>
              String.pad_trailing(delta, 12) <>
              "#{ratio}x"
          )

          {t, baseline}
        end)

      IO.puts("")
      IO.puts("Baseline: #{format_time(elem({nil, baseline_time}, 1))}")
    end

    IO.puts("")
    IO.puts("Legend:")
    IO.puts("  Time    = median of #{iterations} runs")
    IO.puts("  us/op   = microseconds per effect operation (get + put = 1 op)")
    IO.puts("  Delta   = marginal cost added by this step")
    IO.puts("  vs base = cumulative ratio vs S0 baseline")
  end
end

OverheadBenchmark.run()
