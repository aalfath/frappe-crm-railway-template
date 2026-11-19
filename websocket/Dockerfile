# Frappe CRM websocket: Frappe's Socket.IO server (realtime updates in the CRM UI), port 9000.
FROM ghcr.io/frappe/crm:v16.1.0@sha256:8614fe0ac8cac6c45e91ad328854aac3bd7729b3417795b8df59566a4c4fd73b

USER frappe
WORKDIR /home/frappe/frappe-bench
COPY --chown=frappe:root start.sh /opt/railway/start.sh
ENTRYPOINT []
CMD ["bash", "/opt/railway/start.sh"]
