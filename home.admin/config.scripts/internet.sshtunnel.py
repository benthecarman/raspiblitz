#!/usr/bin/python3

import sys, subprocess
from pathlib import Path

# display config script info
if len(sys.argv) <= 1 or sys.argv[1] == "-h" or sys.argv[1] == "help":
    print("forward ports from another server to raspiblitz with reverse SSH tunnel")
    print("internet.sshtunnel.py [on|off] [USER]@[SERVER] [INTERNAL-PORT]:[EXTERNAL-PORT]")
    print("note that [INTERNAL-PORT]:[EXTERNAL-PORT] can one or multiple forwardings")
    sys.exit(1)

#
# CONSTANTS
#

SERVICENAME="autossh-tunnel.service"
SERVICEFILE="/etc/systemd/system/"+SERVICENAME
SERVICETEMPLATE="""# see config script internet.sshtunnel.py
[Unit]
Description=AutoSSH tunnel service
After=network.target

[Service]
User=root
Group=root
Environment="AUTOSSH_GATETIME=0"
ExecStart=/usr/bin/autossh -M 0 -N -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o "ServerAliveInterval 30" -o "ServerAliveCountMax 3" [PLACEHOLDER]
StandardOutput=journal

[Install]
WantedBy=multi-user.target
"""

#
# SWITCHING ON
#

if sys.argv[1] == "on":

    # check if already running
    try:
      subprocess.call("systemctl is-enabled %s" % (SERVICENAME) ,shell=True, universal_newlines=True)
    except subprocess.CalledProcessError as e:
      print("already ON - run 'internet.sshtunnel.py off' first")
      sys.exit(1)

    # check server address
    if len(sys.argv) < 3:
        print("[USER]@[SERVER] missing - use 'internet.sshtunnel.py -h' for help")
        sys.exit(1)
    if sys.argv[2].count("@") != 1:
        print("[USER]@[SERVER] wrong - use 'internet.sshtunnel.py -h' for help")
        sys.exit(1)
    ssh_server = sys.argv[2]

    # genenate additional parameter for autossh (forwarding ports)
    if len(sys.argv) < 4:
        print("[INTERNAL-PORT]:[EXTERNAL-PORT] missing - run 'internet.sshtunnel.py off' first")
        sys.exit(1)
    additional_parameters=""
    i = 3
    while i < len(sys.argv):

        # check forwarding format
        if sys.argv[i].count(":") != 1:
            print("[INTERNAL-PORT]:[EXTERNAL-PORT] wrong format '%s'" % (sys.argv[i]))
            sys.exit(1)

        # get ports
        ports = sys.argv[i].split(":")
        port_internal = ports[0]
        port_external = ports[1]
        if port_internal.isdigit() == False:
            print("[INTERNAL-PORT]:[EXTERNAL-PORT] internal not number '%s'" % (sys.argv[i]))
            sys.exit(1)
        if port_external.isdigit() == False:
            print("[INTERNAL-PORT]:[EXTERNAL-PORT] external not number '%s'" % (sys.argv[i]))
            sys.exit(1) 

        additional_parameters= additional_parameters + "-R %s:localhost:%s " % (port_external,port_internal)
        i=i+1

    # genenate additional parameter for autossh (server)
    additional_parameters= additional_parameters + ssh_server

    # generate custom service config
    service_data = SERVICETEMPLATE.replace("[PLACEHOLDER]", additional_parameters)

    # debug print out service
    print()
    print("*** New systemd service: %s" % (SERVICENAME))
    print(service_data)

    # write service file
    service_file = open("./temp.service", "w")
    service_file.write(service_data)
    service_file.close()
    subprocess.call("sudo mv ./temp.service SERVICEFILE", shell=True)

    # check if SSH keys for root user need to be created
    print()
    print("*** Checking root SSH keys")
    sshkeys_exist = subprocess.check_output("sudo ls /root/.ssh/id_rsa.pub | grep -c 'id_rsa.pub'", shell=True, universal_newlines=True)
    print(sshkeys_exist)
    if str(sshkeys_exist).count("1") == 0:
        print("Generating root SSH keys ...")
        subprocess.call("sudo -u root ssh-keygen -b 2048 -t rsa -f ~/.ssh/id_rsa  -q -N \"\"", shell=True)
        print("DONE")
    else:
        print("OK - root id_rsa.pub file exists")
    ssh_pubkey = subprocess.check_output("sudo cat /root/.ssh/id_rsa.pub", shell=True, universal_newlines=True)

    # make sure autossh is installed
    # https://www.everythingcli.org/ssh-tunnelling-for-fun-and-profit-autossh/
    print()
    print("*** Install autossh")
    subprocess.call("sudo apt-get install -y autossh", shell=True)
    
    # enable service
    print()
    print("*** Enabling systemd service: %s" % (SERVICENAME))
    subprocess.call("sudo systemctl daemon-reload", shell=True)
    subprocess.call("sudo systemctl enable %s" % (SERVICENAME), shell=True)

    # final info (can be ignored if run by other script)
    print()
    print("*** OK - SSH TUNNEL SERVICE DONE SETUP ***")
    print("For details see chapter '' in:")
    print("https://github.com/rootzoll/raspiblitz/blob/master/FAQ.md")
    print("- Tunnel service needs final reboot to start.")
    print("- After reboot check logs: sudo journalctl -f -u %s" % (SERVICENAME))
    print("- Make sure the SSH pub key of this RaspiBlitz is in 'authorized_keys' of %s :" % (ssh_server))
    print(ssh_pubkey)
    print()

#
# SWITCHING OFF
#

elif sys.argv[1] == "off":

    print("*** Disabling systemd service: %s" % (SERVICENAME))
    subprocess.call("sudo systemctl stop %s" % (SERVICENAME), shell=True)
    subprocess.call("sudo systemctl disable %s" % (SERVICENAME), shell=True)
    subprocess.call("sudo rm %s" % (SERVICEFILE), shell=True)
    subprocess.call("sudo systemctl daemon-reload", shell=True)
    print("OK Done")
    print()

#
# UNKOWN PARAMETER
#

else:
    print ("unkown parameter - use 'internet.sshtunnel.py -h' for help")