#!/bin/bash

# --- 函数定义 ---

CHECK_OS(){
	# 更优先使用 /etc/os-release (如果存在)
	if [ -f /etc/os-release ]; then
		. /etc/os-release
		release=$ID # $ID 会是 debian, ubuntu, centos 等
	# 备用检测方法
	elif [[ -f /etc/redhat-release ]]; then
		release="centos"
	elif cat /etc/issue | grep -q -E -i "debian"; then
		release="debian"
	elif cat /etc/issue | grep -q -E -i "ubuntu"; then
		release="ubuntu"
	elif cat /etc/issue | grep -q -E -i "centos|red hat|redhat"; then
		release="centos"
	# 更进一步的备用检测
	elif cat /proc/version | grep -q -E -i "debian"; then
		release="debian"
	elif cat /proc/version | grep -q -E -i "ubuntu"; then
		release="ubuntu"
	elif cat /proc/version | grep -q -E -i "centos|red hat|redhat"; then
		release="centos"
	else
		echo "无法检测到操作系统类型。"
		exit 1
	fi
	echo "检测到操作系统: ${release}"
}

GET_SETTING_FAIL2BAN_INFO(){
	# 设置默认值，如果需要可以修改
	BLOCKING_THRESHOLD='10' # 尝试次数阈值
	BLOCKING_TIME_H='12'   # 封禁小时数

	# 计算封禁秒数
	BLOCKING_TIME_S=$(expr ${BLOCKING_TIME_H} \* 3600)
}

INSTALL_FAIL2BAN(){
	if command -v fail2ban-server &> /dev/null; then
		echo "Fail2ban 似乎已经安装了。"
		# 可以选择退出，或者继续执行设置
		# exit 0
	fi

	CHECK_OS
	GET_SETTING_FAIL2BAN_INFO # 获取设置变量

	case "${release}" in
		centos)
			echo "正在为 CentOS 安装 Fail2ban..."
			yum -y install epel-release
			yum -y install fail2ban fail2ban-firewalld # CentOS 通常用 firewalld
			;;
		debian|ubuntu)
			echo "正在为 ${release} 安装 Fail2ban..."
			apt-get update
			apt-get -y install fail2ban
			;;
		*)
			echo "错误: 不支持的操作系统 ${release}."
			exit 1
			;;
	esac
	echo "Fail2ban 安装完成。"
}

REMOVE_FAIL2BAN(){
	if ! command -v fail2ban-server &> /dev/null; then
		echo "Fail2ban 尚未安装。"
		exit 0
	fi

	CHECK_OS
	case "${release}" in
		centos)
			echo "正在为 CentOS 卸载 Fail2ban..."
			if systemctl is-active --quiet fail2ban; then
				systemctl stop fail2ban
			fi
			yum -y remove fail2ban fail2ban-firewalld
			;;
		debian|ubuntu)
			echo "正在为 ${release} 卸载 Fail2ban..."
			if systemctl is-active --quiet fail2ban; then
				systemctl stop fail2ban
			fi
			apt-get -y purge fail2ban # 使用 purge 删除配置文件
			apt-get -y autoremove
			;;
		*)
			echo "错误: 不支持的操作系统 ${release}."
			exit 1
			;;
	esac
	# 不再需要手动删除 jail.local，purge 会处理
	# rm -rf /etc/fail2ban/jail.local
	echo "Fail2ban 卸载完成。"
}

# --- 修改后的 SETTING_FAIL2BAN 函数 ---
SETTING_FAIL2BAN(){
	CHECK_OS
	GET_SETTING_FAIL2BAN_INFO # 确保变量已设置

	# 检查 fail2ban 服务是否存在
	if ! command -v fail2ban-server &> /dev/null; then
		echo "错误: Fail2ban 未安装。请先运行 install。"
		exit 1
	fi

	# 创建 jail.local 文件的目录（如果不存在）
	mkdir -p /etc/fail2ban/

	echo "正在配置 /etc/fail2ban/jail.local..."

	local ssh_log_config="" # 用于存储日志相关的配置行
	local ssh_jail_name="sshd" # 使用标准的 jail 名称 [sshd]

	case "${release}" in
		centos)
			# CentOS 通常使用 /var/log/secure 和 firewalld
			# 如果需要支持旧版 CentOS 的 iptables，这里需要更多判断
			ssh_log_config="logpath = /var/log/secure\nbackend = auto"
			# 使用 firewalld action 更现代
			local ssh_action="action = %(action_mwl)s"
			local ssh_banaction="banaction = firewallcmd-ipset"
			echo "为 CentOS 配置 logpath=/var/log/secure 和 firewalld/ipset..."
			;;
		debian|ubuntu)
			# 检测日志后端
			if [ -f /var/log/auth.log ]; then
				# 文件存在，假设使用文件日志
				ssh_log_config="logpath = /var/log/auth.log\nbackend = auto"
				echo "检测到 /var/log/auth.log，配置 logpath。"
			elif systemctl is-active --quiet systemd-journald; then
				# 文件不存在，但 journald 运行中，使用 systemd 后端
				ssh_log_config="backend = systemd"
				echo "未找到 /var/log/auth.log，配置 systemd backend。"
			else
				# 无法确定，提供警告并默认使用 systemd
				echo "警告: 无法可靠地确定 SSH 日志源。默认使用 systemd backend。"
				ssh_log_config="backend = systemd"
			fi
			# Debian/Ubuntu 通常使用 iptables action
			local ssh_action="action = iptables[name=SSH, port=ssh, protocol=tcp]"
			local ssh_banaction="" # iptables action 不需要单独的 banaction
			;;
		*)
			echo "错误: 不支持的操作系统 ${release}."
			exit 1
			;;
	esac

	# 使用 printf 和  tee 生成 jail.local 文件
	# 包含 [DEFAULT] 和 [sshd] (使用标准名称)
	printf "[DEFAULT]\n\
ignoreip = 127.0.0.1/8 ::1\n\
bantime = %s\n\
findtime = 3600\n\
maxretry = %s\n" \
		"${BLOCKING_TIME_S}" \
		"${BLOCKING_THRESHOLD}" \
		| tee /etc/fail2ban/jail.local > /dev/null

	# 追加 [sshd] 部分
	printf "\n[%s]\n\
enabled = true\n\
port = ssh\n\
filter = sshd\n\
%s\n\
%s\n" \
		"${ssh_jail_name}" \
		"${ssh_action}" \
		"${ssh_log_config}" \
		| tee -a /etc/fail2ban/jail.local > /dev/null

	# 如果 CentOS 配置了 banaction，追加它
	if [ -n "$ssh_banaction" ]; then
		printf "%s\n" "${ssh_banaction}" |  tee -a /etc/fail2ban/jail.local > /dev/null
	fi

	# --- 结束 [sshd] 配置，可以继续添加其他 jail ---


	# 重启和启用服务 (使用 systemctl 优先)
	echo "正在重启和启用 Fail2ban 服务..."
	if command -v systemctl &> /dev/null; then
		 systemctl restart fail2ban
		 systemctl enable fail2ban
		# 重启 sshd 不是必须的，除非修改了 sshd 配置
		#  systemctl restart sshd
	else
		# 兼容旧系统
		 service fail2ban restart
		if command -v chkconfig &> /dev/null; then
			 chkconfig fail2ban on
		elif command -v update-rc.d &> /dev/null; then
			 update-rc.d fail2ban defaults
		fi
		#  service ssh restart
	fi
	echo "Fail2ban 配置完成并已启动。"
}
# --- 结束修改后的 SETTING_FAIL2BAN 函数 ---

VIEW_RUN_LOG(){
	echo "正在查看 Fail2ban 日志 (/var/log/fail2ban.log)..."
	if [ -f /var/log/fail2ban.log ]; then
		 tail -f /var/log/fail2ban.log
	else
		echo "未找到 /var/log/fail2ban.log。尝试查看 systemd journal:"
		 journalctl -f -u fail2ban.service
	fi
}

# --- 主逻辑 ---

case "${1}" in
	install)
		INSTALL_FAIL2BAN
		SETTING_FAIL2BAN
		;;
	uninstall)
		REMOVE_FAIL2BAN
		;;
	setting) # 添加一个单独的设置命令
		SETTING_FAIL2BAN
		;;
	status)
		if ! command -v fail2ban-client &> /dev/null; then echo "Fail2ban 未安装."; exit 1; fi
		echo -e "\033[41;37m【Service Status】\033[0m"
		if command -v systemctl &> /dev/null; then
			 systemctl status fail2ban --no-pager
		else
			 service fail2ban status
		fi
		echo; echo -e "\033[41;37m【Client Ping】\033[0m"
		 fail2ban-client ping
		;;
	blocklist|bl)
		if ! command -v fail2ban-client &> /dev/null; then echo "Fail2ban 未安装."; exit 1; fi
		echo "查看 [sshd] jail 的状态和封禁列表:" # 使用标准名称
		 fail2ban-client status sshd
		;;
	unlock|ul)
		if ! command -v fail2ban-client &> /dev/null; then echo "Fail2ban 未安装."; exit 1; fi
		TARGET_IP="${2}"
		if [[ -z "${TARGET_IP}" ]]; then
			read -p "请输入需要解封的IP地址: " TARGET_IP
			if [[ -z "${TARGET_IP}" ]]; then
				echo "错误: IP 地址不能为空。"
				exit 1
			fi
		fi
		echo "正在为 [sshd] jail 解封 IP: ${TARGET_IP}..." # 使用标准名称
		 fail2ban-client set sshd unbanip "${TARGET_IP}"
		;;
	more)
		echo "【参考文章】"
		echo "https://www.fail2ban.org"
		echo "https://linux.cn/article-5067-1.html"
		echo ""
		echo "【更多命令】"
		echo "fail2ban-client -h";;
	runlog)
		VIEW_RUN_LOG
		;;
	start)
		echo "正在启动 Fail2ban 服务..."
		if command -v systemctl &> /dev/null; then  systemctl start fail2ban; else  service fail2ban start; fi
		;;
	stop)
		echo "正在停止 Fail2ban 服务..."
		if command -v systemctl &> /dev/null; then  systemctl stop fail2ban; else  service fail2ban stop; fi
		;;
	restart)
		echo "正在重启 Fail2ban 服务..."
		if command -v systemctl &> /dev/null; then  systemctl restart fail2ban; else  service fail2ban restart; fi
		;;
	*)
		echo "用法: bash $0 {install|uninstall|setting|status|blocklist|bl|unlock|ul|runlog|more}"
		echo "         bash $0 {start|stop|restart}"
		exit 1
		;;
esac

exit 0
#END
