# The Hidden Trap of Ansible Asynchronous Execution (`poll: 0`)

This document details an advanced behavioral edge case discovered during real-time process tracing of Ansible asynchronous tasks within containerized (Podman) environments.

## The Core Question
**Why does a task on a target node (`centos1`) get reported as successful (`failed=0`) in the final `PLAY RECAP` and debug contexts, even though operating system metrics prove the task process was terminated by a `SIGKILL` mid-run?**

---

## 🛠️ The Architecture & Laboratory Proof

### 1. The Playbook Setup
The behavior occurs under the following task configuration conditions:
* **`async: 10`**: Establishes a strict 10-second timeout threshold.
* **`poll: 0`**: Triggers fire-and-forget asynchronous execution mode.
* **Playbook Lifespan Extension**: A separate, blocking task later in the playbook (`sleep 40` with `poll: 1` on `rocky2`) keeps the master Ansible orchestrator process open for over 40 seconds.

### 2. Operating System Tracing (Reality)
Running a one-second monitoring loop (`podman top centos1 | grep sleep`) reveals what happens at the target container's kernel level:

```text
Second 2:  Process forks -> /usr/bin/sleep 30
Second 10: Process running -> Elapsed: 10.27s
Second 11: Process running -> Elapsed: 11.37s (Breached async threshold!)
Second 14: Process running -> Elapsed: 14.77s
Second 15: Process vanishes completely (Terminated by Remote Timeout Daemon)
```

The process is forcibly killed at the **15-second mark** (representing 10 seconds of execution time + ~5 seconds of connection and container wrapper framework setup overhead). **The task explicitly failed at the OS level.**

### 3. Ansible Orchestration Report (The Illusion)
Despite the process murder, the playbook execution logs capture this final state:

```text
PLAY RECAP *******************************************************************
centos1                    : ok=3    changed=1    unreachable=0    failed=0 ...
```

The registered variable contents inside the debug block show:
```json
"msg": {
    "ansible_job_id": "j190519088240.4630",
    "changed": true,
    "failed": 0,
    "finished": 0,
    "started": 1
}
```

---

## 💡 Why This Happens (The Technical Breakdown)

### 1. The Frozen Variable Snapshot
When a task is configured with `poll: 0`, Ansible's control node connects to the target machine, triggers the background job wrapper, and **disconnects instantly**. 
* The moment the background process successfully launches (`started: 1`), Ansible marks the task execution block as complete.
* It saves a permanent return payload snapshot stating `"failed": 0, "finished": 0` into the registered variable. 
* Any subsequent `debug` task simply reads this frozen historical snapshot. It does not actively re-query the target node to find out what happened later.

### 2. The Remote Timeout Daemon
Ansible does not run a persistent engine on the target machine. Instead, it deploys transient background helper scripts. 
* Because a blocking task on a separate host (`rocky2`) keeps the master playbook session open, the local background tracking directory (`~/.ansible_async/`) on the target machine remains alive.
* The remote tracking daemon successfully counts down, identifies that the process has breached its `async: 10` boundary, and fires a termination signal.

### 3. Why the `PLAY RECAP` Shows `failed=0`
The final `PLAY RECAP` only accumulates failure flags if an error is returned **while the master engine is actively watching that specific task block**. 
Because `poll: 0` instructs the master orchestrator to look away immediately, the background murder of your process occurs entirely "off-the-books." As far as the central Ansible play loop is concerned, it perfectly performed the fire-and-forget hand-off you requested.

---

## 🛡️ Best Practices & Remediation

If your workflow requires fire-and-forget execution but cannot tolerate silent task failures, you **must not** rely on the default task completion status or play recaps. 

You must explicitly use the **`async_status`** module later in your playbook execution path paired with a retry loop to force Ansible to actively check the state of the captured Job ID:

```yaml
- name: Actively wait until Task 1 finishes on centos1
  async_status:
    jid: "{{ hostvars['centos1']['result1']['ansible_job_id'] }}"
  when: inventory_hostname == "centos1"
  register: job_check
  until: job_check.finished == 1
  retries: 15
  delay: 1
```

Using this pattern forces Ansible to query the live status files, returning `"finished": 1` upon normal completion, or capturing an explicit `Timeout exceeded` message if it fails.

Here is the playbook: [demoAsynchronousTasks.yaml](https://github.com/dkmahadeva/DevLinux/blob/main/demoAsynchronousTasks.yaml)
