INSTALL_DIR = /data/docker/agent
PORTS ?= 443

.PHONY: deploy update

deploy:
	sudo bash deploy/install-xray.sh $(PORTS)
	sudo bash deploy/install-agent.sh

update:
	git pull origin dev
	sudo cp main.py $(INSTALL_DIR)/main.py
	sudo cp requirements.txt $(INSTALL_DIR)/requirements.txt
	sudo cp -r app $(INSTALL_DIR)/app
	sudo $(INSTALL_DIR)/venv/bin/pip install -q -r $(INSTALL_DIR)/requirements.txt
	sudo systemctl restart vpn-agent
