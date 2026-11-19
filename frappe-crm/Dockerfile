# Frappe CRM web service: nginx (public, PORT), gunicorn and the background worker.
# Upstream's ghcr.io/frappe/crm image ships only the Frappe framework, so the CRM app is
# installed here from the matching release tag.
FROM ghcr.io/frappe/crm:v16.1.0@sha256:8614fe0ac8cac6c45e91ad328854aac3bd7729b3417795b8df59566a4c4fd73b

ARG CRM_REF=v16.1.0
USER frappe
WORKDIR /home/frappe/frappe-bench
# The image keeps built assets in ./assets; link them so `bench get-app` builds CRM's assets there.
RUN ln -s /home/frappe/frappe-bench/assets sites/assets \
 && bench get-app --branch "$CRM_REF" https://github.com/frappe/crm \
 && rm sites/assets \
 && rm -rf apps/crm/.git apps/crm/node_modules apps/crm/frontend/node_modules \
 && test -f apps/crm/crm/www/crm.html \
 && env/bin/python -c "import crm; print('crm', crm.__version__)"

USER root
COPY start.sh /opt/railway/start.sh
ENTRYPOINT []
CMD ["bash", "/opt/railway/start.sh"]
