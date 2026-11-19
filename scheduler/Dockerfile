# Frappe CRM scheduler: `bench schedule`, which queues CRM's periodic jobs for the worker.
# Needs the CRM Python app (for its scheduler hooks) but not its web assets.
FROM ghcr.io/frappe/crm:v16.1.0@sha256:8614fe0ac8cac6c45e91ad328854aac3bd7729b3417795b8df59566a4c4fd73b

ARG CRM_REF=v16.1.0
USER frappe
WORKDIR /home/frappe/frappe-bench
RUN bench get-app --skip-assets --branch "$CRM_REF" https://github.com/frappe/crm \
 && rm -rf apps/crm/.git apps/crm/node_modules apps/crm/frontend/node_modules \
 && env/bin/python -c "import crm; print('crm', crm.__version__)"

COPY --chown=frappe:root start.sh /opt/railway/start.sh
ENTRYPOINT []
CMD ["bash", "/opt/railway/start.sh"]
