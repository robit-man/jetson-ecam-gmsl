/*
 * Copyright (C) 2018 e-con Systems Pvt Ltd, Inc. All Rights Reserved.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.

 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 */

#ifndef __TB_H
#define __TB_H

/* TB Register Sets */
#define SIOA_TB_ID  0x0D
#define SIOB_TB_ID  0x0F
#define DEF_TB_ID   0x0E

typedef struct _tb_reg {
	u16 reg;
	u16 val;
} TB_REG;



TB_REG CMN_MIPI_TX_BASE[] = {

//	{0x0016, 0x3062},
	{0x0018, 0x0603},	
//	{0x0020, 0x0015},	 
	{0xFFFF, 0x03E8},	
	{0x0018, 0x0613},	
	{0x0006, 0x0000},	
	{0x0008, 0x0060},
	{0x0022, 0x0F00},	

	{0x0140, 0x0000},
	{0x0142, 0x0000},
	{0x0144, 0x0000},
	{0x0146, 0x0000},
	{0x0148, 0x0000},
	{0x014A, 0x0000},
	{0x014C, 0x0000},
	{0x014E, 0x0000},
	{0x0150, 0x0000},
	{0x0152, 0x0000},
	{0x0210, 0x0BB8},	
	{0x0212, 0x0000},
	{0x0214, 0x0002},
	{0x0216, 0x0000},
//	{0x0218, 0x1002},
	{0x021A, 0x0000},
	{0x0220, 0x0002},
	{0x0222, 0x0000},
	{0x0224, 0x4E20},
	{0x0226, 0x0000},
//	{0x022C, 0x0001},
	{0x022E, 0x0000},
	{0x0230, 0x0005},
	{0x0232, 0x0000},
	{0x0234, 0x001F},
	{0x0236, 0x0000},
	{0x0238, 0x0001},	
	{0x023A, 0x0000},
	{0x0204, 0x0001},
	{0x0206, 0x0000},

	{0x0518, 0x0001},
	{0x051A, 0x0000},
	{0x0500, 0x8086},
	{0x0502, 0xA300},
	{0x0004, 0x0143},
};

TB_REG AR0233_MIPI_TX_BASE[] = {
	{0x0016, 0x306d},
	{0x0218, 0x1001},
	{0x022C, 0x0000},
};

TB_REG AR0230_MIPI_TX_BASE[] = {
	{0x0016, 0x3062},
	{0x0020, 0x0015},	 	
	{0x0218, 0x1002},
	{0x022C, 0x0001},
};
static int tb_write_i2c(struct i2c_client *client, u8 * val, u32 count,u8);
static int tb_read_i2c(struct i2c_client *client, u8 * val, u32 count,u8);
static s32 tb_read_16b_reg(struct i2c_client *client, u16 reg, u16 * val,u8);
static s32 tb_write_16b_reg(struct i2c_client *client, u16 reg, u16 val,u8);
static s32 tb_parse_regdata(struct i2c_client *client, TB_REG * regdata,
			    u32 reg_cnt,u8);
int ecam_tb_config( struct i2c_client *client, struct cam *priv);
#endif /*__TB_H*/
