/*
 * pca9685.c - pca9685 support driver
* Copyright (c) 2015-2016, e-con Systems.  All rights reserved.
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms and conditions of the GNU General Public License,
 * version 2, as published by the Free Software Foundation.
 *
 * This program is distributed in the hope it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
 * more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

#define PCA9685_FLAG
#include <linux/gpio/consumer.h>
#include "pca9685.h"

/**@brief pca9685 register read function,
 * This function reads a specific register of pca9685 pwm IC,
 * Transferring two messages at time,
 * First message with write flag and a single byte length data is to select a 8bit register,
 * Second message with read flag to obtain a byte data from the selected register. 
 * @return returns 0 if successful
 */
static int pca9685_reg_read(u8 reg, u8 *val){

	int ret;
	struct i2c_msg msg[] = {
		{
			.addr	= PCA9685_ADDRESS,
			.flags	= I2C_M_WR,
			.len	= 1,
			.buf	= &reg,
		},
		{
			.addr	= PCA9685_ADDRESS,
			.flags	= I2C_M_RD,
			.len	= 1,
			.buf	= val,
		}
	};

	ret = i2c_transfer(pca9685_adapter, msg, 2);
	if (ret < 0)
		return ret;

	return 0;
}

/** @brief pca9685 register write function,
 *  This function write a specific register of pca9685 pwm IC,
 *  Transferring one message with write command of 2 byte data length,
 *  First byte to select register,
 *  Second byte is written into the selected register,
 *  @return returns 0 if successful
 */
static int pca9685_reg_write(u8 reg, u8 val){

	int ret;
	unsigned char data[2] = { reg, val };
	struct i2c_msg msg = {
		.addr	= PCA9685_ADDRESS,
		.flags	= I2C_M_WR,
		.len	= 2,
		.buf	= data,
	};

	ret = i2c_transfer(pca9685_adapter, &msg, 1);
	udelay(100);

	if (ret < 0) 
		return ret;

	return 0;
}

/** @brief pca9685 register write a bit function
 *  This function updates a bit of specific register of pca9685 pwm IC
 *  @return returns 0 if successful
 */
static int pca9685_reg_write_bits(u8 reg, u8 mask, u8 val){

	int ret;
	u8 data = 0;
	u8 temp;

	ret = pca9685_reg_read(reg,&temp);
	if(ret)
		return ret;

	temp = data & ~mask; 
	temp |= val & mask;
 
	/* Return if read value and modified value are same */
	if(temp == data)  
		return 0; 

	ret = pca9685_reg_write(reg,temp);
	if(ret)
		return ret;

	return 0;
}

/** @brief PWM Calibration initialization function
 *  This function sets up the calibration GPIO, calibration threads and the IRQ
 *  @return returns 0 if successful
 */
int calibration_init(int num){

	int result = 0, ret=0;

	/*Recalibration can be done ONLY if last_sync_mode not matched with   
	 *current calibration request else return here itself */
	if(last_calib_val == 2)
		last_calib_val = num;
	else if(last_calib_val != num)
		last_calib_val = num;
	else
		return 0;

	/* Create the PWM Calibration thread */
	st_calib_start = kthread_create(thread_calibrate_pwm, NULL, "pwm_auto_calib_thread");
	if (st_calib_start)
		pr_info("Thread Created successfully\n");
	else
		printk(KERN_ERR "Thread creation failed\n");

	/* Create the thread to finish PWM calibration */
	st_calib_stop = kthread_create(thread_finish_pwm_calib, NULL, "pwm_stop_auto_calib_stop_thread");
	if (st_calib_stop)
		pr_info("PWM stop Thread Created successfully\n");
	else
		printk(KERN_ERR "PWM stop Thread creation failed\n");

	// GPIO validation
	if (!gpio_is_valid(pwm_calib_gpio)){
		printk(KERN_ERR "Invalid GPIO \n");
		return -ENODEV;
	}

	/* Set up the pwm_calib_gpio */
	if (!gpio_req_flag){
		ret= gpio_request(pwm_calib_gpio, "sysfs");
		gpio_req_flag++;
		if(ret){
			printk("\nGPIO request failed\n");
			return ret;
		}
		else
			printk("\nGPIO request success!!\n");
	}
	/* Set the GPIO to be an input */
	gpio_direction_input(pwm_calib_gpio);  
	/* Causes gpio to appear in /sys/class/gpio */
	gpiod_export(gpio_to_desc(pwm_calib_gpio), false);          
	/* the bool argument prevents the direction from being changed */
	irq_number = gpio_to_irq(pwm_calib_gpio);

	if(psc_lookup[num] == 0 )
		prescaler_val = pre_limit[num].psc_start;
	else
		prescaler_val = psc_lookup[num];

	pwm_mode = num;
	wake_up_process(st_calib_start);
	udelay(500);

	/* This next call requests an interrupt line */
	result = request_irq(irq_number,
			(irq_handler_t) calibration_irq_handler,
			IRQF_TRIGGER_RISING,
			"pwm_auto_calib_handler",
			NULL);
	return result;
}

/** @brief Calibration GPIO IRQ Handler function
 *  This function is a custom interrupt handler that is attached to the Calibration GPIO.
 */
static irq_handler_t calibration_irq_handler(unsigned int irq, void *dev_id, struct pt_regs *regs){

	static unsigned int ignore_samples = 0;
	static int t0 = 0, t1 = 0;

	/* Ignoring Five Samples to stable the PWM Frequency */
	if(ignore_samples++ < 5) {
		ktime_get_real_ts64(&ts);
		t0 = (int) ts.tv_nsec/100000;
	} else {
		ktime_get_real_ts64(&ts);
		t1 =(int) ts.tv_nsec/100000;

	 /*Change the prescalar value Based on PWM Frequency limit*/
		if( !((t1-t0) >= pre_limit[pwm_mode].pwm_low_limit && (t1-t0) <= pre_limit[pwm_mode].pwm_high_limit) ) {
			ignore_samples = 0;
			if( (t1-t0) <= pre_limit[pwm_mode].pwm_high_limit) {
				wake_up_process(st_calib_start);
				udelay(500);
			} else {
				pr_info("prescalar value=%x\n",prescaler_val);
				prescaler_val = prescaler_val - 2;
				wake_up_process(st_calib_start);
				udelay(500);
			}
	/* Calibrated PWM and Stop calibration process */
		} else {
			printk(KERN_INFO "%s PWM Calibrated.. \n",__func__);
			psc_lookup[pwm_mode] = prescaler_val - 1;
			wake_up_process(st_calib_stop);
			udelay(500);
		}
	}

	return (irq_handler_t) IRQ_HANDLED;
}

/** @brief Calibration thread
 *  This thread will write the appropriate Prescalar value
 *  to get the desired frequency output from the PWM Chip
 */
static int thread_calibrate_pwm(void *data){

	int err;
	irq_status = true;
	 
	while (!kthread_should_stop()) {

		err = pca9685_set_frequency(prescaler_val);
		prescaler_val++;
		set_current_state(TASK_INTERRUPTIBLE);
		schedule();
	}
	
	return 0;

}

static int thread_finish_pwm_calib(void *data){
	
	while (!kthread_should_stop()) {
		udelay(500);
		if (st_calib_start)	{
			kthread_stop(st_calib_start);
			//put_task_struct(st_calib_start);
			st_calib_start = NULL;
		}
		if (irq_status == true) {
			free_irq(irq_number, NULL);
			irq_status = false;
			/* do_exit() is not exported since Linux 5.17; returning ends the kthread the same way. */
			return 0;
		}
	}
	return 0;
}

 /** @brief PWM Calibration cleanup function
 *  This function releases the calibration GPIO, calibration threads and the IRQ
 */
void calibration_exit(void){
	
	if (st_calib_start)	{
		kthread_stop(st_calib_start);
		//put_task_struct(st_calib_start);
		st_calib_start = NULL;
	}
	if (irq_status == true) {
		free_irq(irq_number, NULL);
		irq_status = false;
	}
	gpiod_unexport(gpio_to_desc(pwm_calib_gpio));
	gpio_free(pwm_calib_gpio);
}

/** @brief pca9685 frequency set function
 *  This function sets the frequency for pca9685 pwm IC by doing necessary
 *  @return returns 0 if successful
 */
static int pca9685_set_frequency(int prescale){

	int err;
	 	
	if (prescale >= PCA9685_PRESCALE_MIN && prescale <= PCA9685_PRESCALE_MAX) {
		
		/* Put chip into sleep mode */
		if( (err = pca9685_reg_write_bits(PCA9685_MODE1,MODE1_SLEEP,MODE1_SLEEP)) )
			return err;

		/* Change the chip-wide output frequency */
		if( (err = pca9685_reg_write(PCA9685_PRESCALE, prescale)) )
			return err;

		/* Wake the chip up */
		if( (err = pca9685_reg_write_bits(PCA9685_MODE1,MODE1_SLEEP, CLEAR)) )
			return err;
	
		if( (err = pca9685_reg_write_bits(PCA9685_MODE1,MODE1_RESTART,MODE1_RESTART)) )
			return err;

		/* Wait 500us for the oscillator to be back up */
		udelay(500);

	} else 
		return -EINVAL;
	
	return 0;
}

/** @brief pca9685 duty cycle setting function
 *  This function sets the duty cycle for "LANE_NOS" of pwm pin starting from "START_LANE" pwm pin of pca9685 pwm IC
 *  @return returns 0 if successful
 */
static int pca9685_set_duty_cycle(int duty_ns, int period_ns){

	unsigned long long duty;
	unsigned int reg;
	int ret;
	int index;

	/* Setting For Almost Negligible Duty Cycle */
	if (duty_ns < 1) {
		
		
		reg = LED_N_OFF_H(START_LANE);
		for(index=0; index<LANE_NOS; index++,reg=LED_N_OFF_H(index))
			if( (ret = pca9685_reg_write(reg,LED_FULL)) )
				return ret;

		return 0;
	}
	
	/* Setting for Max. Duty Cycle */
	if (duty_ns == period_ns) {
		/* Clear both OFF registers */
		reg = LED_N_OFF_H(START_LANE);
		for(index=0; index<LANE_NOS;index++,reg=LED_N_OFF_H(index))
			if( (ret = pca9685_reg_write(reg,0x0)) )
				return ret;

		reg = LED_N_OFF_H(START_LANE);
		for(index=0; index<LANE_NOS;index++,reg=LED_N_OFF_H(index))
			if( (ret = pca9685_reg_write(reg,0x0)) )
				return ret;

		/* Set the full ON bit */
		reg = LED_N_ON_H(START_LANE);
		for(index=0; index<LANE_NOS;index++,reg=LED_N_OFF_H(index))
			if( (ret = pca9685_reg_write(reg,LED_FULL)) )
				return ret;

		return 0;
	}

	/* Setting for requested duty cycle */
	duty = PCA9685_COUNTER_RANGE * (unsigned long long)duty_ns;
	duty = DIV_ROUND_UP_ULL(duty, period_ns);

	reg = LED_N_OFF_L(START_LANE);
	for(index=0; index<LANE_NOS; index++,reg=LED_N_OFF_L(index))
		if( (ret = pca9685_reg_write(reg,(int)duty & 0xff)) )
			return ret;

	reg = LED_N_OFF_H(START_LANE);
	for(index=0; index<LANE_NOS; index++,reg=LED_N_OFF_H(index))
		if( (ret = pca9685_reg_write(reg,((int)duty >> 8) & 0xf)) )
			return ret;

	/* Clear the full on registers, otherwise the set OFF time has no effect */
	reg = LED_N_ON_H(START_LANE);
	for(index=0; index<LANE_NOS; index++,reg=LED_N_ON_H(index))
		if( (ret = pca9685_reg_write(reg,0)) )
			return ret;

	reg = LED_N_ON_L(START_LANE);
	for(index=0; index<LANE_NOS; index++,reg=LED_N_ON_L(index))
		if( (ret = pca9685_reg_write(reg,0)) )
			return ret;

	return 0;
	
}

/** @brief pca9685 configuration function
 *  This function is used to set the frequency and duty cycle of pca9685 pwm IC
 *  @return returns 0 if successful
 */
static int pca9685_config(struct i2c_client *client, int duty_ns, int period_ns,uint8_t current_calib_mode){

	int err;
	int prescale;

	prescale = DIV_ROUND_CLOSEST(PCA9685_OSC_CLOCK_MHZ * period_ns,
			PCA9685_COUNTER_RANGE * 1000) - 1;
	err = pca9685_set_frequency(prescale);
	if(err){
		dev_err(&client->dev, "Failed to set the baud rate! %d\n",err);
		return err;
	}
	err = pca9685_set_duty_cycle(duty_ns,period_ns);
	if(err){
		dev_err(&client->dev, "Failed to set the duty cycle! %d\n",err);
		return err;
	}
	calibration_init(MAX_PWM_MODE - current_calib_mode);

	return 0;
}

/** @brief pca9685 initialization function
 *  This function is used to set the register required for setting up pca9685 pwm IC
 *  @return returns 0 if successful
 */
int pca9685_init(struct i2c_client *client, uint8_t fps){

	u8 mode2 = 0,current_calib_mode;
	int duty_ns = -1, period_ns = -1;
	int ret = 0;
	static uint8_t current_fps = 28;

	pca9685_adapter = i2c_get_adapter(ECON_MULTILANE_BASEBOARD_BUS_ADDRESS);
	pr_info("pca9685 bus address : %d\n",(int)pca9685_adapter->nr);

	if(fps != current_fps){
		pca9685_init_flag = 0;
		current_fps = fps;
	}
	if(pca9685_init_flag){
		pr_info("%s pca9685 IC already initialized..\n",__func__);
		return 0;
	}

	ret = pca9685_reg_read(PCA9685_MODE2,&mode2);
	if(ret){
		dev_err(&client->dev, "Failed to Read from mode2 register of pca9685driver %d\n",ret);
		return ret;
	}

	if (device_property_read_bool(&client->dev, "pwm-invert"))
		mode2 |= MODE2_INVRT;
	else
		mode2 &= ~MODE2_INVRT;

	if (device_property_read_bool(&client->dev, "pwm-open-drain"))
		mode2 &= ~MODE2_OUTDRV;
	else
		mode2 |= MODE2_OUTDRV;

	ret = pca9685_reg_write(PCA9685_MODE2,mode2);
	if(ret){
		dev_err(&client->dev, "Failed to write on mode2 register of pca9685 driver %d\n",ret);
		return ret;
	}

	/* clear all "full off" bits */
	if( pca9685_reg_write( PCA9685_ALL_LED_OFF_L, 0) ||  pca9685_reg_write(PCA9685_ALL_LED_OFF_H, 0) )
		return -EINVAL;

	if(fps != SECONDARY_FPS){
		//Get duty cycle, time period and calibration pin from dtb
		ret = device_property_read_u32(&client->dev, "pwm-duty_ns", &duty_ns);
		if(ret){
			dev_err(&client->dev, "Failed to Read register map with error %d\n",ret);
			return ret;
		}
		ret = device_property_read_u32(&client->dev, "pwm-period_ns", &period_ns);
		if(ret){
			dev_err(&client->dev, "Failed to Read register map with error %d\n",ret);
			return ret;
		}
		current_calib_mode = 2;
	}
	else{/*Values for Secondary fps calibration */
		duty_ns = 0x1CBC720;/* 10% duty_cycle*/
		period_ns = 0x2037FE7;
		current_calib_mode = 1;
	}
	pr_info("pwm period=%d\n",period_ns);
	pwm_calib_gpio = of_get_named_gpio(client->dev.of_node, "pwm-calib-gpio", 0);
	if(pwm_calib_gpio<0){
		dev_err(&client->dev, "Failed to Read register map with error %d\n",ret);
		return ret;
	}

	//Configure duty cycle and frequency
	ret = pca9685_config(client,duty_ns,period_ns,current_calib_mode);
	if(ret){
		dev_err(&client->dev, "Failed to Configure the pca9685 chip %d\n",ret);
		return ret;
	}

	pca9685_init_flag = 1;
	pr_info("%s pca9685 initialized successfully!\n",__func__);
	return 0;
}

