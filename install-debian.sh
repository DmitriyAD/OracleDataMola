#!/bin/bash

if [ "$(id  -u)" = "0" ]
then
  echo "Start script as user!"
  exit 1
fi

read -d . DEBIAN_VERSION < /etc/debian_version
if [ "$DEBIAN_VERSION" != "11" ]
then
  echo "You should run Debian 11!"
  exit 1
fi

if ! grep xterm "$HOME/.xsession" > /dev/null
then
  echo "Configure container with XTerm graphics over VNC or X11!"
  exit 1
fi

### environment

KLIPPER="$HOME/klipper"
MOONRAKER="$HOME/moonraker"
KLIPPERSCREEN="$HOME/KlipperScreen"

KLIPPER_START="/etc/init.d/klipper"
MOONRAKER_START="/etc/init.d/moonraker"

KLIPPER_CONFIG="$HOME/klipper_config"
GCODE_FILES="$HOME/gcode_files"

KLIPPERSCREEN_XTERM="/usr/local/bin/xterm"

TTYFIX="/usr/bin/ttyfix"
TTYFIX_START="/etc/init.d/ttyfix"

### Mounting /tmp


sudo mount -o mode=1777,nosuid,nodev -t tmpfs tmpfs /tmp

### packages


sudo apt update
sudo apt install -y \
  git inotify-tools virtualenv libffi-dev build-essential libncurses-dev libusb-dev stm32flash libnewlib-arm-none-eabi gcc-arm-none-eabi binutils-arm-none-eabi libusb-1.0-0 pkg-config dfu-util \
  python3-virtualenv python3-dev python3-libgpiod liblmdb0 libsodium-dev zlib1g-dev libjpeg-dev libcurl4-openssl-dev libssl-dev \
  python3-tornado python3-serial python3-pillow python3-lmdb python3-libnacl python3-paho-mqtt python3-pycurl curl \
  libopenjp2-7 python3-distutils python3-gi python3-gi-cairo gir1.2-gtk-3.0 wireless-tools libatlas-base-dev fonts-freefont-ttf python3-websocket python3-requests python3-humanize python3-jinja2 python3-ruamel.yaml python3-matplotlib
sudo apt install -f
sudo apt clean

### git

git clone https://github.com/KevinOConnor/klipper.git $KLIPPER
git clone https://github.com/Arksine/moonraker.git $MOONRAKER
git clone https://github.com/jordanruthe/KlipperScreen.git $KLIPPERSCREEN

### folders


mkdir -p $KLIPPER_CONFIG
mkdir -p $GCODE_FILES

### configs



sed -i "s#serial:.*#serial: /dev/ttyACM0#" $KLIPPER_CONFIG/printer.cfg
sed -i "1 i [include kiauh_macros.cfg]" $KLIPPER_CONFIG/printer.cfg
cp -f $KLIPPERSCREEN/ks_includes/defaults.conf $KLIPPER_CONFIG/KlipperScreen.conf

### klipper


sudo python3 -m pip install setuptools wheel
sudo python3 -m pip install -r $KLIPPER/scripts/klippy-requirements.txt

sudo python3 -m pip cache purge

### moonraker


sudo pip3 install -U pip setuptools wheel
sudo pip3 install --no-use-pep517 "$(grep "streaming-form-data" ${MOONRAKER}/scripts/moonraker-requirements.txt)"
sudo pip3 install --no-use-pep517 "$(grep "distro" ${MOONRAKER}/scripts/moonraker-requirements.txt)"
sudo pip3 install --no-use-pep517 "$(grep "inotify-simple" ${MOONRAKER}/scripts/moonraker-requirements.txt)"

for n in tornado pyserial pillow lmdb libnacl paho-mqtt pycurl
do
  sed -i "s#$n.*#$n#" ${MOONRAKER}/scripts/moonraker-requirements.txt
done
sudo pip3 install --no-use-pep517 -r ${MOONRAKER}/scripts/moonraker-requirements.txt

### KlipperScreen


for n in humanize jinja2 matplotlib requests websocket-client
do
  sed -i "s#$n.*#$n#" ${KLIPPERSCREEN}/scripts/KlipperScreen-requirements.txt
done
sudo pip3 install --no-use-pep517 "$(grep "netifaces" ${KLIPPERSCREEN}/scripts/KlipperScreen-requirements.txt)"
sudo pip3 install --no-use-pep517 "$(grep "vext" ${KLIPPERSCREEN}/scripts/KlipperScreen-requirements.txt)"
sudo pip3 install -r ${KLIPPERSCREEN}/scripts/KlipperScreen-requirements.txt

sudo pip3 cache purge

sudo tee "$KLIPPERSCREEN_XTERM" <<EOF
#!/bin/bash

cd $KLIPPERSCREEN
exec python3 ./screen.py
EOF
sudo chmod +x "$KLIPPERSCREEN_XTERM"

cat <<EOF > ${KLIPPER_CONFIG}/moonraker.conf
[server]
host: 0.0.0.0
port: 7125
enable_debug_logging: False
config_path: $KLIPPER_CONFIG
database_path: ~/.moonraker_database
klippy_uds_address: /tmp/klippy_uds

[authorization]
trusted_clients:
    127.0.0.1
    192.168.0.0/16
    ::1/128
    FE80::/10
cors_domains:
    *.lan
    *.local
    *://my.mainsail.xyz
    *://app.fluidd.xyz
    *://dev-app.fluidd.xyz

[octoprint_compat]

[history]
EOF

### autostart

sudo tee "$TTYFIX" <<EOF
#!/bin/bash

inotifywait -m /dev -e create |
  while read dir action file
  do
    [ "\$file" = "ttyACM0" ] && chmod 777 /dev/ttyACM0
  done
EOF
sudo chmod +x "$TTYFIX"

sudo tee "$TTYFIX_START" <<EOF
#!/bin/sh
### BEGIN INIT INFO
# Provides:          ttyfix
# Default-Start:        2 3 4 5
# Default-Stop:
# Required-Start:    \$local_fs \$remote_fs
# Short-Description: ttyfix
# Description: ttyfix
### END INIT INFO

. /lib/lsb/init-functions

N="$TTYFIX_START"
PIDFILE=/run/ttyfix.pid
EXEC="$TTYFIX"

set -e

f_start ()
{
  start-stop-daemon --start --background --make-pidfile --pidfile \$PIDFILE --exec \$EXEC
}

f_stop ()
{
  start-stop-daemon --stop --pidfile \$PIDFILE
}

case "\$1" in
  start)
        f_start
        ;;
  stop)
        f_stop
        ;;
  restart)
        f_stop
        sleep 1
        f_start
        ;;
  reload|force-reload|status)
        ;;
  *)
        echo "Usage: $N {start|stop|restart|force-reload|status}" >&2
        exit 1
        ;;
esac

exit 0
EOF
sudo chmod +x "$TTYFIX_START"

sudo mv /usr/bin/systemctl /usr/bin/systemctl2
sudo tee /usr/bin/systemctl <<EOF
#!/bin/bash

if [ "\$1" = "list-units" ]
then
 echo "klipper.service"
 echo "moonraker.service"
 exit 0
fi

/usr/sbin/service "\$2" "\$1"
EOF
sudo chmod +x /usr/bin/systemctl

sudo tee $KLIPPER_START <<EOF
#!/bin/sh
### BEGIN INIT INFO
# Provides:          klipper
# Default-Start:        2 3 4 5
# Default-Stop:
# Required-Start:    \$local_fs \$remote_fs
# Short-Description: klipper
# Description: klipper
### END INIT INFO

. /lib/lsb/init-functions

N=$KLIPPER_START
PIDFILE=/run/klipper.pid
USERNAME=$USER
EXEC="/usr/bin/python2.7"
EXEC_OPTS="/home/\$USERNAME/klipper/klippy/klippy.py /home/\$USERNAME/klipper_config/printer.cfg -l /tmp/klippy.log -a /tmp/klippy_uds"

set -e

f_start ()
{
  chmod 777 /dev/ttyACM0 ||:
  mount -o mode=1777,nosuid,nodev -t tmpfs tmpfs /tmp
  start-stop-daemon --start --background --chuid \$USERNAME --make-pidfile --pidfile \$PIDFILE --exec \$EXEC -- \$EXEC_OPTS
}

f_stop ()
{
  start-stop-daemon --stop --pidfile \$PIDFILE
}

case "\$1" in
  start)
        f_start
        ;;
  stop)
        f_stop
        ;;
  restart)
        f_stop
        sleep 1
        f_start
        ;;
  reload|force-reload|status)
        ;;
  *)
        echo "Usage: $N {start|stop|restart|force-reload|status}" >&2
        exit 1
        ;;
esac

exit 0
EOF
sudo chmod +x $KLIPPER_START

sudo tee $MOONRAKER_START <<EOF
#!/bin/sh
### BEGIN INIT INFO
# Provides:          moonraker
# Default-Start:        2 3 4 5
# Default-Stop:
# Required-Start:    \$local_fs \$remote_fs klipper
# Short-Description: moonraker
# Description: moonraker
### END INIT INFO

. /lib/lsb/init-functions

N=$MOONRAKER_START
PIDFILE=/run/moonraker.pid
USERNAME=$USER
EXEC="/usr/bin/python3"
EXEC_OPTS="/home/\$USERNAME/moonraker/moonraker/moonraker.py -c /home/\$USERNAME/klipper_config/moonraker.conf -l /tmp/moonraker.log"

set -e

f_start ()
{
  start-stop-daemon --start --background --chuid \$USERNAME --make-pidfile --pidfile \$PIDFILE --exec \$EXEC -- \$EXEC_OPTS
}

f_stop ()
{
  start-stop-daemon --stop --pidfile \$PIDFILE
}

case "\$1" in
  start)
        f_start
        ;;
  stop)
        f_stop
        ;;
  restart)
        f_stop
        sleep 1
        f_start
        ;;
  reload|force-reload|status)
        ;;
  *)
        echo "Usage: $N {start|stop|restart|force-reload|status}" >&2
        exit 1
        ;;
esac

exit 0
EOF
sudo chmod +x $MOONRAKER_START

sudo update-rc.d klipper defaults
sudo update-rc.d moonraker defaults
sudo update-rc.d ttyfix defaults

echo "Starting klipper and moonraker services now"

sudo service ttyfix start
sudo service klipper start
sleep 10
sudo service moonraker start

echo "Starting KlipperScreen instead of XTerm"

sudo pkill xterm
export DISPLAY=:0
xterm >/dev/null 2>&1 &

### complete
echo "Installation completed!"
