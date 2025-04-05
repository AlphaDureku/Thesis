from odoo import models, fields, api
from odoo.exceptions import UserError
import logging
_logger = logging.getLogger(__name__)

class VSSurety(models.TransientModel):
    _name = "shp.vs_surety_wizard"
    _description = "Borrow Credit Wizard"

    dealer_id = fields.Many2one('shp.partners', string="Dealer")
    amount = fields.Float(string="Credit Amount")
    reason = fields.Text(string="Reason", required=True)
    sale_order_id = fields.Many2one('sale.order', string="Sales Order")
    borrow_from = fields.Many2one(
        'shp.partners', 
        string="Available Upline GM or GD to Borrow from",
        required=True
    )
    successfully_borrowed = fields.Boolean(string="successfully_borrowed")
    borrow_from_ids = fields.Many2many('shp.partners')
    attachment = fields.Binary(string="Attachment")  # Stores files (images, PDFs, etc.)
    attachment_filename = fields.Char(string="Filename")  # Stores the filename
        
    @api.model
    def default_get(self, fields_list):
        res = super().default_get(fields_list)
        context = self.env.context
    
        res.update({
            'dealer_id': context.get('default_dealer_id'),
            'amount': context.get('default_amount'),
            'sale_order_id': context.get('default_sale_order_id'),
        })
    
        collected_gm_and_gd = []  # Stores GM and GD
    
        # Get the current borrower (dealer) from context
        current_borrower = self.env['shp.partners'].browse(context.get('default_dealer_id'))
    
        if not current_borrower:
            return res  # No dealer found, return early
    
        # Get GD (Motherline Director)
        gd = current_borrower.motherline_director if current_borrower.motherline_director and current_borrower.motherline_director.cl_available >= context.get('default_amount') and not current_borrower.motherline_director.has_vs_overdue else None
        if gd:
            collected_gm_and_gd.append(gd.id)
    
        # If dealer is weight 2, it can only borrow from GD, return early
        if current_borrower.r_grade_id.weight == 2:
            res.update({'borrow_from_ids': [(6, 0, collected_gm_and_gd)]})
            return res
    
        # If dealer is weight 1, search for the first GM
        recruiter = current_borrower.recruiter
        default_amount = context.get('default_amount') or 0
    
        # Fetch eligible surety ranks once
        eligible_surety_ranks = self.env['shp.config.credit_line'].search([], limit=1).eligible_surety.ids if self.env['shp.config.credit_line'].search([], limit=1) else []
    
        if not eligible_surety_ranks:
            _logger.info("No Available Surety")
    
        while recruiter:
            if (
                recruiter.r_grade_id.weight in eligible_surety_ranks
                and recruiter.cl_available >= default_amount
            ):
                if recruiter.r_grade_id.weight == 2:  # First GM found
                    if recruiter.cl_available >= context.get('default_amount') and not recruiter.has_vs_overdue:
                        collected_gm_and_gd.append(recruiter.id)
                    break  # Stop searching once GM is found
    
            recruiter = recruiter.recruiter
    
        res.update({'borrow_from_ids': [(6, 0, collected_gm_and_gd)]})
        return res


    def action_confirm_borrow(self):
        """Action when confirming the borrowing of credit."""
        sale_order = self.env['sale.order'].browse(self._context.get('active_id'))
    
        vs_record_created = self.env['shp.vs_account_records'].create({
            'displayName': self.env['ir.sequence'].next_by_code('shp.vs_account_records.code'),
            'lender_id': self.borrow_from.id,
            'borrower_id': self.dealer_id.id,
            'total_lent': self.amount,
            'reason': self.reason,
            'sales_order_id': self.sale_order_id.id,
            'attachment': self.attachment,
            'attachment_filename': self.attachment_filename,
        })
        self.sale_order_id.related_borrow_id = vs_record_created
        # sale_order.action_confirm()
        return {
            'effect': {
                'fadeout': 'slow',
                'message': "Credit Borrowed Successfully!",
                'type': 'rainbow_man',
            }
        }




    # def _create_notification_action(self, title, message, record=None, model_name=None, action_xml_id=None, view_type='form'):
    #     """Generates a UI notification action.
        
    #     If a record, its model name, and the corresponding action's XML ID are provided,
    #     a clickable link is added to the notification.
    #     """
    #     notification = {
    #         'type': 'ir.actions.client',
    #         'tag': 'display_notification',
    #         'params': {
    #             'title': title,
    #             'message': '%s',
    #             'sticky': False,
    #         },
    #     }
    #     if record and model_name and action_xml_id:
    #         action = self.env.ref(action_xml_id)
    #         notification['params']['links'] = [{
    #             'label': message + record.vs_transaction_name,
    #             'url': f'/web#action={action.id}&id={record.id}&model={model_name}&view_type={view_type}',
    #         }]
    #     return notification