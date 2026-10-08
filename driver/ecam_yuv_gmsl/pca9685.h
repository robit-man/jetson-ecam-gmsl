/*
 * pca9685.h - pca9685 driver IC headers 
 *
 * Copyright (c) 2015-2016, e-con Systems, All Rights Reserved.
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms and conditions of the GNU General Public License,
 * version 2, as published by the Free Software Foundation.
 *
 * This program is distributed in the hope it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
 * more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <http://www.gnu.org/licenses/>.
 */

#ifdef PCA9685_FLAG

#include <linux/i2c.h>
#include <linux/delay.h>
#include <linux/of_gpio.h>
#include <linux/interrupt.h>            
#include <linux/kthread.h>
#include <linux/efi.h>

#define PCA9685_MODE1		0x00
#define PCA9685_MODE2		0x01
#define PCA9685_LEDX_ON_L	0x06
#define PCA9685_LEDX_ON_H	0x07
#define PCA9685_LEDX_OFF_L	0x08
#define PCA9685_LEDX_OFF_H	0x09
#define PCA9685_ALL_LED_OFF_L	0xFC
#define PCA9685_ALL_LED_OFF_H	0xFD
#define PCA9685_PRESCALE	0xFE

#define PCA9685_PRESCALE_MIN	0x03	/* => max. frequency of 1526 Hz */
#define PCA9685_PRESCALE_MAX	0xFF	/* => min. frequency of 24 Hz */

#define PCA9685_COUNTER_RANGE	4096
#define PCA9685_OSC_CLOCK_MHZ	25	/* Internal oscillator with 25 MHz */

#define PCA9685_NUMREGS		0xFF

#define LED_FULL		(1 << 4)
#define MODE1_RESTART		(1 << 7)
#define MODE1_SLEEP		(1 << 4)
#define MODE2_INVRT		(1 << 4)
#define MODE2_OUTDRV		(1 << 2)
#define CLEAR	0

#define LED_N_ON_H(N)	(PCA9685_LEDX_ON_H + (4 * (N)))
#define LED_N_ON_L(N)	(PCA9685_LEDX_ON_L + (4 * (N)))
#define LED_N_OFF_H(N)	(PCA9685_LEDX_OFF_H + (4 * (N)))
#define LED_N_OFF_L(N)	(PCA9685_LEDX_OFF_L + (4 * (N)))


#define MAX_PWM_MODE 3	// Maximum PWM modes supported
#define PCA9685_ADDRESS 0x61 //pca9685 slave address
#define LANE_NOS 7  //Mention number of cameras connected here
#define START_LANE 0
#define I2C_M_WR 0x00
#define ECON_MULTILANE_BASEBOARD_BUS_ADDRESS 12
#define SECONDARY_FPS 28
static irq_handler_t calibration_irq_handler(unsigned int irq, void *dev_id, struct pt_regs *regs);

int last_calib_val = 2;
static int gpio_req_flag=0;
static int thread_calibrate_pwm(void *);
static int thread_finish_pwm_calib(void *);

static int pca9685_reg_read(u8,u8*);
static int pca9685_reg_write(u8,u8);
static int pca9685_reg_write_bits(u8,u8,u8);
static int pca9685_set_frequency(int);
static int pca9685_set_duty_cycle(int,int);
static int pca9685_config(struct i2c_client*,int,int,uint8_t);


static struct task_struct *st_calib_start;
static struct task_struct *st_calib_stop;
struct i2c_adapter *pca9685_adapter;

struct timespec64 ts;
struct regmap *g_regmap;

static unsigned int pwm_calib_gpio = -1; // Gpio for PWM calibration got from DTB file
static unsigned int irq_number;

static int prescaler_val;
static int pca9685_init_flag = 0;

static bool irq_status = true;

struct psc_mode {
	int pwm_low_limit;
	int pwm_high_limit;
	int psc_start;
};

static struct psc_mode pre_limit[MAX_PWM_MODE] = {
	/* This below exposure time period value setting is for ar1335 sensor*/
	//{340,342,0xD0},       // 29.49Hz to 29.67Hz
	{360,362,0xE7},/*27.5 TO 27.7*//*FHD_HDR*/
	{337,340,0xD8},/*29.4 TO 29.6*//*FHD*/
	{167,169,0x6A},/* 59.57 TO 59.72 */
};

static int psc_lookup[MAX_PWM_MODE] = {0};
static int pwm_mode;

#endif

int pca9685_init(struct i2c_client*,uint8_t);
int calibration_init(int);
void calibration_exit(void);


