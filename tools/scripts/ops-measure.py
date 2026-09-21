#!/usr/bin/env python3
"""Mede o que a trilha `operacao` afirma, contra a stack Compose no ar.

Cada número que uma lição de operação cita sai daqui. A regra do repositório
vale igual: se a lição diz "8 segundos", alguém cronometrou.

Escreve site/src/data/ops-measured.json.

Uso:  python3 tools/scripts/ops-measure.py            (precisa da stack no ar)
      SKIP_PSI=1 python3 tools/scripts/ops-measure.py (pula a carga de CPU)
"""
import json, os, pathlib, re, subprocess, sys, time

RAIZ = pathlib.Path(__file__).resolve().parents[2]
COMPOSE = ["docker", "compose", "-f", "stack/compose.yaml", "-f", "stack/compose.prod.yaml"]
PSQL = 'PGPASSWORD=$(cat /run/secrets/postgres_password) psql -U links -d links -tAF"|" -q'


def sh(*args, entrada=None, timeout=300):
    return subprocess.run(args, capture_output=True, text=True,
                          input=entrada, cwd=RAIZ, timeout=timeout).stdout.strip()


def cid(servico):
    return sh(*COMPOSE, "ps", "-q", servico)


def psql(sql):
    """Roda SQL no db. `-i` é OBRIGATÓRIO: sem ele o heredoc é descartado em
    silêncio, o psql recebe EOF, sai com 0 e não imprime nada (armadilha 31)."""
    return sh("docker", "exec", "-i", cid("db"), "sh", "-c", PSQL, entrada=sql)


# ─── 1. O container é um processo do host ────────────────────────────────────
def processo():
    """O mesmo processo, dois pontos de vista — e o nome de usuário diverge.

    O UID dentro do container É o UID no host: não há tradução enquanto o
    user namespace estiver desligado, que é o padrão do Docker. O `ps` do host
    resolve esse número pelo /etc/passwd DO HOST, então um Postgres rodando
    como UID 70 aparece com o nome que o host der ao 70.
    """
    out = {}
    for svc in ("api", "worker", "db"):
        c = cid(svc)
        if not c:
            continue
        pid = sh("docker", "inspect", "--format", "{{.State.Pid}}", c)
        uid = sh("ps", "-o", "uid=", "-p", pid).strip()
        nome = sh("ps", "-o", "user=", "-p", pid).strip()
        comm = sh("ps", "-o", "comm=", "-p", pid).strip()
        passwd = sh("getent", "passwd", uid)
        out[svc] = {
            "pidNoHost": int(pid) if pid.isdigit() else None,
            "uid": int(uid) if uid.isdigit() else None,
            "nomeNoHost": nome,
            "comm": comm,
            # Se o UID não existe no /etc/passwd do host, o `ps` mostra o
            # número cru — e é assim que se sabe que não houve tradução.
            "existeNoPasswdDoHost": bool(passwd),
            "entradaNoPasswdDoHost": passwd.split(":")[0] if passwd else None,
        }
    out["userNamespaceRemapLigado"] = "userns-remap" in sh("cat", "/etc/docker/daemon.json")
    return out


# ─── 2. cgroup v2: o limite, lido de dentro ──────────────────────────────────
def cgroup():
    c = cid("worker")
    campos = ["memory.max", "memory.current", "memory.high", "cpu.max",
              "pids.max", "memory.events"]
    lido = sh("docker", "exec", c, "sh", "-c",
              " ; ".join(f'echo "{f}=$(cat /sys/fs/cgroup/{f} | tr "\\n" " ")"' for f in campos))
    out = {}
    for linha in lido.splitlines():
        if "=" in linha:
            k, v = linha.split("=", 1)
            out[k] = v.strip()
    return out


# ─── 3. O OOM killer, provocado ──────────────────────────────────────────────
def oom():
    """Aloca até o kernel matar, num container descartável de 64 MiB.

    O que interessa não é que morre: é COMO. SIGKILL não é capturável, então
    não há `defer`, `finally` nem handler que rode. 137 = 128 + 9.
    """
    script = ("import time\n"
              "b=[]\n"
              "while True:\n"
              "    b.append(bytearray(8*1024*1024))\n")
    nome = "ops-oom-probe"
    subprocess.run(["docker", "rm", "-f", nome], capture_output=True)
    t0 = time.monotonic()
    subprocess.run(["docker", "run", "--name", nome, "--memory=64m",
                    "--memory-swap=64m", "python:3.13-alpine",
                    "python", "-c", script], capture_output=True, timeout=180)
    dur = time.monotonic() - t0
    estado = sh("docker", "inspect", nome, "--format",
                "{{.State.OOMKilled}}|{{.State.ExitCode}}")
    subprocess.run(["docker", "rm", "-f", nome], capture_output=True)
    morto, codigo = (estado.split("|") + ["", ""])[:2]
    return {
        "limiteMiB": 64,
        "oomKilled": morto == "true",
        "exitCode": int(codigo) if codigo.isdigit() else None,
        "segundosAteMorrer": round(dur, 2),
        "_nota": "137 = 128 + 9 (SIGKILL). Não é capturável: nenhum handler roda.",
    }


# ─── 4. Pressão (PSI) não é uso ──────────────────────────────────────────────
def psi():
    """Uso e pressão são grandezas diferentes, e a diferença é o ensinamento.

    Com uma tarefa por núcleo a CPU fica em 100% de USO e quase zero de
    PRESSÃO: ninguém espera. Com quatro tarefas por núcleo o uso continua
    100% e a pressão explode — é o mesmo recurso ocupado, com fila.
    """
    def linha(arquivo="cpu"):
        v = sh("head", "-1", f"/proc/pressure/{arquivo}")
        m = re.search(r"avg10=([\d.]+)", v)
        return float(m.group(1)) if m else None

    def carga(tarefas, segundos):
        procs = [subprocess.Popen(["bash", "-c", "while :; do :; done"],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                 for _ in range(tarefas)]
        time.sleep(segundos)
        v = linha()
        load = float(sh("cut", "-d ", "-f1", "/proc/loadavg") or 0)
        for p in procs:
            p.kill()
        for p in procs:
            p.wait()
        return v, load

    nucleos = int(sh("nproc") or 1)
    time.sleep(20)                      # deixa a pressão anterior escoar
    repouso = linha()
    um_por_nucleo, load1 = carga(nucleos, 18)
    time.sleep(35)
    quatro_por_nucleo, load4 = carga(nucleos * 4, 18)
    return {
        "nucleos": nucleos,
        "repousoAvg10": repouso,
        "umaTarefaPorNucleoAvg10": um_por_nucleo,
        "umaTarefaPorNucleoLoad": load1,
        "quatroTarefasPorNucleoAvg10": quatro_por_nucleo,
        "quatroTarefasPorNucleoLoad": load4,
        "_nota": ("Nos dois casos o uso de CPU é ~100%. A pressão é que muda: "
                  "ela mede TEMPO DE ESPERA, não ocupação."),
    }


# ─── 5. DNS: o nome que custa oito segundos ──────────────────────────────────
def dns():
    """Um rótulo que o resolvedor embutido não conhece é encaminhado adiante,
    e o resolvedor de cima não responde consulta de rótulo único. Dois
    rótulos inexistentes voltam com NXDOMAIN na hora."""
    prog = (
        "import socket,time,json\n"
        "casos=[('db',1,'existe, mesma rede'),('edge',1,'existe na stack, OUTRA rede'),"
        "('naoexisteninguem',1,'nao existe'),('zq7x4k2m9p1v3n8w.com',2,'nao existe'),"
        "('naoexiste.local',2,'.local e reservado'),('example.com',2,'existe na internet')]\n"
        "r=[]\n"
        "for n,rot,nota in casos:\n"
        "    t=time.monotonic()\n"
        "    try:\n"
        "        socket.gethostbyname(n); ok=True\n"
        "    except Exception:\n"
        "        ok=False\n"
        "    r.append({'nome':n,'rotulos':rot,'ms':round((time.monotonic()-t)*1000,1),"
        "'resolveu':ok,'nota':nota})\n"
        "print(json.dumps(r))\n"
    )
    saida = sh("docker", "exec", "-i", cid("worker"), "python3", "-c", prog, timeout=180)
    try:
        casos = json.loads(saida.splitlines()[-1])
    except Exception:
        return {"erro": "não consegui medir o DNS", "bruto": saida[:200]}
    lento = max((c for c in casos if not c["resolveu"] and c["rotulos"] == 1),
                key=lambda c: c["ms"], default=None)
    rapido = min((c for c in casos if not c["resolveu"] and c["rotulos"] == 2),
                 key=lambda c: c["ms"], default=None)
    return {
        "resolvConf": sh("docker", "exec", cid("worker"), "cat", "/etc/resolv.conf"),
        "casos": casos,
        "piorRotuloUnicoMs": lento["ms"] if lento else None,
        "melhorDoisRotulosMs": rapido["ms"] if rapido else None,
        "razao": (round(lento["ms"] / rapido["ms"]) if lento and rapido and rapido["ms"] else None),
    }


# ─── 6. O Postgres que você opera ────────────────────────────────────────────
def postgres():
    psql("DROP TABLE IF EXISTS ops_demo;")
    psql("CREATE TABLE ops_demo AS SELECT g id, md5(g::text) v "
         "FROM generate_series(1,200000) g; ANALYZE ops_demo;")

    def sort(work_mem):
        saida = psql(f"SET work_mem='{work_mem}';\n"
                     "EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF) "
                     "SELECT v FROM ops_demo ORDER BY v;")
        metodo = re.search(r"Sort Method: ([^\n]+)", saida)
        tempo = re.search(r"Execution Time: ([\d.]+)", saida)
        return {"workMem": work_mem,
                "metodo": metodo.group(1).strip() if metodo else None,
                "ms": float(tempo.group(1)) if tempo else None}

    apertado, folgado = sort("4MB"), sort("64MB")

    def tamanho():
        return psql("SELECT pg_size_pretty(pg_relation_size('ops_demo'));")

    antes = tamanho()
    psql("DELETE FROM ops_demo WHERE id % 2 = 0;")
    apos_delete = tamanho()
    psql("VACUUM ops_demo;")
    apos_vacuum = tamanho()
    psql("VACUUM FULL ops_demo;")
    apos_full = tamanho()

    ajustes = {}
    for linha in psql(
        "SELECT name, setting, unit FROM pg_settings WHERE name IN "
        "('shared_buffers','work_mem','effective_cache_size','max_connections',"
        "'autovacuum_vacuum_threshold','autovacuum_vacuum_scale_factor',"
        "'shared_preload_libraries');").splitlines():
        p = linha.split("|")
        if len(p) >= 2:
            ajustes[p[0]] = p[1] + (f" {p[2]}" if len(p) > 2 and p[2] else "")

    psql("DROP TABLE IF EXISTS ops_demo;")
    limite = sh("docker", "exec", cid("db"), "cat", "/sys/fs/cgroup/memory.max")
    return {
        "limiteDoContainerMiB": round(int(limite) / 1048576) if limite.isdigit() else None,
        "ajustes": ajustes,
        "sortApertado": apertado,
        "sortFolgado": folgado,
        "tamanhoAntes": antes,
        "tamanhoAposDelete": apos_delete,
        "tamanhoAposVacuum": apos_vacuum,
        "tamanhoAposVacuumFull": apos_full,
        "_nota": ("DELETE e VACUUM não devolvem espaço ao disco; só o VACUUM FULL "
                  "devolve, ao preço de um lock exclusivo e uma cópia inteira."),
    }


def main():
    import datetime
    dados = {
        "_comentario": ("Medido por tools/scripts/ops-measure.py contra a stack Compose "
                        "no ar. Cada número aqui é citado por uma lição da trilha `operacao`."),
        "geradoEm": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "kernel": sh("uname", "-r"),
        "processo": processo(),
        "cgroup": cgroup(),
        "oom": oom(),
        "dns": dns(),
        "postgres": postgres(),
    }
    dados["psi"] = {"pulado": True} if os.environ.get("SKIP_PSI") == "1" else psi()
    destino = RAIZ / "site/src/data/ops-measured.json"
    destino.write_text(json.dumps(dados, indent=2, ensure_ascii=False) + "\n")
    print(f"   -> {destino.relative_to(RAIZ)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
