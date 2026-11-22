# Activity log tests (feature/audit-log)

Runs on a Docker host, in throwaway containers only (names start with bgaudit-).
Copy this folder to ~/bgaudit-test, then:

    bash rebuild.sh   # extension jar from this branch + test image betterguac:audit-log-test
    bash phase1.sh    # a bg9 install from Docker Hub with a server, users and a group
    bash phase2.sh    # upgrade those volumes to the branch image (migration + backup)
    bash phase3.sh    # every event type, the API, CSV, retention, permissions
    bash phase4.sh    # idempotence, edited/failed migrations, restore drill, fresh install

Cleanup: docker rm -f bgaudit-bg bgaudit-ssh bgaudit-fresh; docker volume rm bgaudit_{db,conf,state,logs,fdb,fconf,fstate,flogs}
