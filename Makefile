INSTALL_DIR = /opt/vpn-agent
PORTS ?= 443

.PHONY: deploy update

deploy:
	sudo bash deploy/install-singbox.sh $(PORTS)
	sudo bash deploy/install-agent.sh

update:
	git pull origin dev
	sudo cp main.py $(INSTALL_DIR)/main.py
	sudo cp requirements.txt $(INSTALL_DIR)/requirements.txt
	sudo $(INSTALL_DIR)/venv/bin/pip install -q -r $(INSTALL_DIR)/requirements.txt
	sudo systemctl restart vpn-agent
