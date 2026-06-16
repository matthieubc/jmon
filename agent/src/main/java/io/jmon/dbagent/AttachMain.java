package io.jmon.dbagent;

import com.sun.tools.attach.VirtualMachine;

public final class AttachMain {
    private AttachMain() {
    }

    public static void main(String[] args) throws Exception {
        if (args.length < 2) {
            System.err.println("usage: AttachMain <pid> <agent-jar> [agent-args]");
            System.exit(2);
            return;
        }

        final String pid = args[0];
        final String agentJar = args[1];
        final String agentArgs = args.length >= 3 ? args[2] : "";

        VirtualMachine vm = null;
        try {
            vm = VirtualMachine.attach(pid);
            vm.loadAgent(agentJar, agentArgs);
        } finally {
            if (vm != null) {
                vm.detach();
            }
        }
    }
}
